#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavutil/buffer.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/frame.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/pixfmt.h>

#include "error.h"
#include "log.h"

#ifdef HAS_VAAPI
#include <fcntl.h>
#include <unistd.h>
#include <libavutil/hwcontext_drm.h>
#include <libavutil/hwcontext_vaapi.h>
#include <va/va.h>
#endif

#define TIME_BASE ((AVRational){1, 1000})

typedef struct ScaleContext
{
	AVFilterGraph* filter_graph_scale;
	AVFilterContext* buffersink_scale_ctx;
	AVFilterContext* buffersrc_scale_ctx;
	AVFrame* frame_in;
	AVFrame* frame_out;
} ScaleContext;

typedef struct Scalers
{
	ScaleContext bgr0;
	ScaleContext rgb0;
	ScaleContext rgb;
	AVBufferRef* hw_frames_ctx;
	AVFrame* frame_out;
} Scalers;

// Zero-copy input: frames arrive as DMA-BUF handles (e.g. from PipeWire) and are imported
// straight into VAAPI surfaces, converted and encoded on the GPU without touching the CPU.
typedef struct DrmContext
{
	AVBufferRef* drm_device;
	AVBufferRef* drm_frames;   // describes the incoming DRM_PRIME frames
	AVBufferRef* vaapi_frames; // VAAPI frames context the DMA-BUFs get mapped into (RGB)
	ScaleContext scale;        // scale_vaapi: RGB -> NV12 at the output size
	uint32_t fourcc;
	uint64_t modifier;
	int width;
	int height;
	int initialized;
} DrmContext;

typedef struct VideoContext
{
	AVFormatContext* oc;
	AVCodecContext* c;

	// pointer to the frame to be encoded, one of frame_out in scalers.bgr0/rgb0/rgb
	AVFrame* frame;

	Scalers scalers;
	DrmContext drm;

	AVBufferRef* hw_device_ctx;

	AVPacket* pkt;
	AVStream* st;
	int width_out;
	int height_out;
	int width_in;
	int height_in;
	void* buf;
	void* rust_ctx;
	int pts;
	int initialized;
	int frame_allocated;
	int gop_size; // frames between keyframes
	int qp;       // quantizer (lower = better quality, more bits); 23 by default
	int try_vaapi;
	int try_nvenc;
	int try_videotoolbox;
	int try_mediafoundation;
} VideoContext;

// this is a rust function and lives in src/video.rs
int write_video_packet(void* rust_ctx, const uint8_t* buf, int buf_size);

#if defined(__clang__) || defined(__GNUC__)
void log_callback(__attribute__((unused)) void* _ptr, int level, const char* fmt_orig, va_list args)
#else
void log_callback(void* _ptr, int level, const char* fmt_orig, va_list args)
#endif
{
	char fmt[256] = {0};
	strncpy(fmt, fmt_orig, sizeof(fmt) - 1);
	int done = 0;
	// strip whitespaces from end
	for (int i = sizeof(fmt) - 1; i >= 0 && !done; --i)
		switch (fmt[i])
		{
		case ' ':
		case '\n':
		case '\t':
		case '\r':
			fmt[i] = '\0';
			break;
		case '\0':
			break;
		default:
			done = 1;
		}
	char buf[2048];
	vsnprintf(buf, sizeof(buf), fmt, args);
	switch (level)
	{
	case AV_LOG_FATAL:
	case AV_LOG_ERROR:
	case AV_LOG_PANIC:
		log_error("%s", buf);
		break;
	case AV_LOG_INFO:
		log_info("%s", buf);
		break;
	case AV_LOG_WARNING:
		log_warn("%s", buf);
		break;
	case AV_LOG_QUIET:
		break;
	case AV_LOG_VERBOSE:
		log_debug("%s", buf);
		break;
	case AV_LOG_DEBUG:
		log_trace("%s", buf);
		break;
	}
}

// called in src/log.rs
void init_ffmpeg_logger() { av_log_set_callback(log_callback); }

void set_codec_params(VideoContext* ctx)
{
	/* resolution must be a multiple of two */
	ctx->c->width = ctx->width_out;
	ctx->c->height = ctx->height_out;
	ctx->c->time_base = TIME_BASE;
	ctx->c->framerate = (AVRational){0, 1};

	ctx->c->gop_size = ctx->gop_size;
	// Describe the colours explicitly. Without this the stream inherits "RGB" from the captured
	// frames and decoders have to guess. Full range because e.g. the i965 VAAPI converter always
	// produces full-range output, and every other path is configured to match.
	ctx->c->colorspace = AVCOL_SPC_BT709;
	ctx->c->color_primaries = AVCOL_PRI_BT709;
	ctx->c->color_trc = AVCOL_TRC_BT709;
	ctx->c->color_range = AVCOL_RANGE_JPEG;
	// no B-frames to reduce latency
	ctx->c->max_b_frames = 0;
	if (ctx->oc->oformat->flags & AVFMT_GLOBALHEADER)
		ctx->c->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
}

void destroy_scale_ctx(ScaleContext* ctx)
{
	avfilter_graph_free(&ctx->filter_graph_scale);
	if (ctx->frame_in)
		av_frame_free(&ctx->frame_in);
}

void init_scaler(
	ScaleContext* ctx,
	int width_in,
	int height_in,
	int width_out,
	int height_out,
	enum AVPixelFormat pix_fmt_in,
	enum AVPixelFormat pix_fmt_out,
	AVBufferRef* hw_device_ctx,
	enum AVPixelFormat pix_fmt_sw_out,
	AVFrame* frame_out,
	int vaapi_sw_convert,
	Error* err)
{
	int ret = 0;

	ctx->frame_in = av_frame_alloc();
	if (!ctx->frame_in)
		ERROR(err, 1, "Failed to allocate frame_in for scale filter!");

	ctx->frame_out = frame_out;

	ctx->frame_in->format = pix_fmt_in;
	ctx->frame_in->width = width_in;
	ctx->frame_in->height = height_in;
	ret = av_frame_get_buffer(ctx->frame_in, 0);
	if (ret)
	{
		destroy_scale_ctx(ctx);
		ERROR(
			err,
			1,
			"Failed to allocate buffer for frame_in for scale filter: %s!",
			av_err2str(ret));
	}

	char args[512];
	const AVFilter* buffersrc = avfilter_get_by_name("buffer");
	const AVFilter* buffersink = avfilter_get_by_name("buffersink");
	AVFilterInOut* outputs = avfilter_inout_alloc();
	AVFilterInOut* inputs = avfilter_inout_alloc();

	ctx->filter_graph_scale = avfilter_graph_alloc();
	if (!outputs || !inputs || !ctx->filter_graph_scale)
	{
		ret = AVERROR(ENOMEM);
		goto end;
	}

	avfilter_graph_set_auto_convert(ctx->filter_graph_scale, AVFILTER_AUTO_CONVERT_NONE);

	/* buffer video source: the decoded frames from the decoder will be inserted here. */
	snprintf(
		args,
		sizeof(args),
		"video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
		width_in,
		height_in,
		pix_fmt_in,
		TIME_BASE.num,
		TIME_BASE.den,
		1,
		1);

	ret = avfilter_graph_create_filter(
		&ctx->buffersrc_scale_ctx, buffersrc, "in", args, NULL, ctx->filter_graph_scale);
	if (ret < 0)
	{
		log_warn("Cannot create buffer source");
		goto end;
	}

	/* buffer video sink: to terminate the filter chain. */
	ctx->buffersink_scale_ctx =
		avfilter_graph_alloc_filter(ctx->filter_graph_scale, buffersink, "out");

	if (ctx->buffersink_scale_ctx == NULL)
	{
		log_warn("Cannot allocate buffer sink");
		goto end;
	}

	ret = av_opt_set_array(
		ctx->buffersink_scale_ctx,
		"pixel_formats",
		AV_OPT_SEARCH_CHILDREN,
		0,
		1,
		AV_OPT_TYPE_PIXEL_FMT,
		&pix_fmt_out);
	if (ret < 0)
	{
		log_warn("Cannot set output pixel format: %s", av_err2str(ret));
		goto end;
	}

	ret = avfilter_init_dict(ctx->buffersink_scale_ctx, NULL);
	if (ret < 0)
	{
		log_warn("Cannot init buffer sink");
		goto end;
	}

	outputs->name = av_strdup("in");
	outputs->filter_ctx = ctx->buffersrc_scale_ctx;
	outputs->pad_idx = 0;
	outputs->next = NULL;

	inputs->name = av_strdup("out");
	inputs->filter_ctx = ctx->buffersink_scale_ctx;
	inputs->pad_idx = 0;
	inputs->next = NULL;

	switch (pix_fmt_out)
	{
	case AV_PIX_FMT_CUDA:
		if (pix_fmt_in == AV_PIX_FMT_RGB24)
		{
			snprintf(
				args,
				sizeof(args),
				"scale=w=%d:h=%d:flags=fast_bilinear,hwupload_cuda",
				width_out,
				height_out);
		}
		else
		{
			snprintf(
				args,
				sizeof(args),
#ifdef HAS_LIBNPP
				"scale,format=nv12,hwupload_cuda,scale_npp=w=%d:h=%d:format=%s:interp_algo=nn",
#else
				"hwupload_cuda,scale_cuda=w=%d:h=%d:format=%s:interp_algo=nearest",
#endif
				width_out,
				height_out,
				av_get_pix_fmt_name(pix_fmt_sw_out));
		}
		break;
	case AV_PIX_FMT_VAAPI:
		if (vaapi_sw_convert)
			// Some drivers (e.g. i965 on Broadwell) can encode but can't convert RGB input on the
			// GPU. Convert to the encoder's format on the CPU and only upload the result.
			snprintf(
				args,
				sizeof(args),
				"scale=w=%d:h=%d:flags=fast_bilinear:out_color_matrix=bt709:out_range=full,format=%s,"
				"hwupload",
				width_out,
				height_out,
				av_get_pix_fmt_name(pix_fmt_sw_out));
		else if (pix_fmt_in == AV_PIX_FMT_RGB24)
			snprintf(
				args,
				sizeof(args),
				"scale=w=%d:h=%d:flags=fast_bilinear:out_color_matrix=bt709:out_range=full,hwupload",
				width_out,
				height_out);
		else
			snprintf(
				args,
				sizeof(args),
				"hwupload,scale_vaapi=w=%d:h=%d:format=%s:mode=fast:out_color_matrix=bt709:"
				"out_range=full:out_color_primaries=bt709:out_color_transfer=bt709",
				width_out,
				height_out,
				av_get_pix_fmt_name(pix_fmt_sw_out));
		break;
	default:
		snprintf(
			args,
			sizeof(args),
			"scale=w=%d:h=%d:flags=fast_bilinear:out_color_matrix=bt709:out_range=full",
			width_out,
			height_out);
	}

	// Since FFmpeg 7.1 a filter's hw_device_ctx must be set *before* the filter is initialized,
	// and avfilter_graph_parse_ptr() initializes filters immediately. Use the segment API so the
	// device can be attached between creating and initializing the filters.
	AVFilterGraphSegment* seg = NULL;
	if ((ret = avfilter_graph_segment_parse(ctx->filter_graph_scale, args, 0, &seg)) < 0)
	{
		log_warn("Failed to parse filter");
		goto end;
	}
	if ((ret = avfilter_graph_segment_create_filters(seg, 0)) < 0)
	{
		log_warn("Failed to create filters");
		avfilter_graph_segment_free(&seg);
		goto end;
	}
	for (size_t i = 0; i < seg->nb_chains; i++)
	{
		AVFilterChain* chain = seg->chains[i];
		for (size_t j = 0; j < chain->nb_filters; j++)
		{
			AVFilterContext* filt = chain->filters[j]->filter;
			if (filt && hw_device_ctx && strcmp(filt->filter->name, "hwupload") == 0)
				filt->hw_device_ctx = av_buffer_ref(hw_device_ctx);
		}
	}
	// Unlike avfilter_graph_parse_ptr(), the segment API doesn't connect the chain to our
	// buffer source/sink; it hands back the chain's open input and output pads instead.
	AVFilterInOut* seg_in = NULL;
	AVFilterInOut* seg_out = NULL;
	ret = avfilter_graph_segment_apply(seg, 0, &seg_in, &seg_out);
	avfilter_graph_segment_free(&seg);
	if (ret >= 0 && (!seg_in || seg_in->next || !seg_out || seg_out->next))
		ret = AVERROR(EINVAL); // expect exactly one open input and one open output
	if (ret >= 0)
		ret = avfilter_link(ctx->buffersrc_scale_ctx, 0, seg_in->filter_ctx, seg_in->pad_idx);
	if (ret >= 0)
		ret = avfilter_link(seg_out->filter_ctx, seg_out->pad_idx, ctx->buffersink_scale_ctx, 0);
	avfilter_inout_free(&seg_in);
	avfilter_inout_free(&seg_out);
	if (ret < 0)
	{
		log_warn("Failed to initialize filter graph: %s", av_err2str(ret));
		goto end;
	}

	if ((ret = avfilter_graph_config(ctx->filter_graph_scale, NULL)) < 0)
	{
		log_warn("Failed to configure filter graph");
		goto end;
	}

end:
	avfilter_inout_free(&inputs);
	avfilter_inout_free(&outputs);

	if (ret != 0)
	{
		destroy_scale_ctx(ctx);
		ERROR(
			err,
			1,
			"Setting up scale filter %s -> %s (sw: %s) failed!",
			av_get_pix_fmt_name(pix_fmt_in),
			av_get_pix_fmt_name(pix_fmt_out),
			av_get_pix_fmt_name(pix_fmt_sw_out));
	}
	else
	{
		log_debug(
			"Scale filter set %s -> %s (sw: %s) up!",
			av_get_pix_fmt_name(pix_fmt_in),
			av_get_pix_fmt_name(pix_fmt_out),
			av_get_pix_fmt_name(pix_fmt_sw_out));
	}
}

void destroy_drm(DrmContext* d)
{
	if (d->scale.frame_out)
		av_frame_free(&d->scale.frame_out);
	if (d->scale.filter_graph_scale)
		avfilter_graph_free(&d->scale.filter_graph_scale);
	av_buffer_unref(&d->vaapi_frames);
	av_buffer_unref(&d->drm_frames);
	av_buffer_unref(&d->drm_device);
	memset(d, 0, sizeof(DrmContext));
}

void destroy_scalers(Scalers* s)
{
	destroy_scale_ctx(&s->bgr0);
	destroy_scale_ctx(&s->rgb0);
	destroy_scale_ctx(&s->rgb);
	if (s->frame_out)
		av_frame_free(&s->frame_out);
}

void init_scalers(
	Scalers* ctx,
	int width_in,
	int height_in,
	int width_out,
	int height_out,
	enum AVPixelFormat pix_fmt_out,
	enum AVPixelFormat pix_fmt_sw_out,
	AVBufferRef* hw_device_ctx,
	Error* err)
{
	int ret;
	ctx->frame_out = av_frame_alloc();
	if (!ctx->frame_out)
	{
		destroy_scalers(ctx);
		ERROR(err, 1, "Failed to allocate frame_out for scale filter!");
	}

	if (hw_device_ctx != NULL)
	{

		AVBufferRef* hw_frames_ref;
		AVHWFramesContext* frames_ctx = NULL;
		if (!(hw_frames_ref = av_hwframe_ctx_alloc(hw_device_ctx)))
		{
			destroy_scalers(ctx);
			ERROR(err, 1, "Failed to create HW frame context.");
		}
		frames_ctx = (AVHWFramesContext*)(hw_frames_ref->data);
		frames_ctx->format = pix_fmt_out;
		frames_ctx->sw_format = pix_fmt_sw_out;
		frames_ctx->width = width_out;
		frames_ctx->height = height_out;
		frames_ctx->initial_pool_size = 20;
		if ((ret = av_hwframe_ctx_init(hw_frames_ref)) < 0)
		{
			av_buffer_unref(&hw_frames_ref);
			destroy_scalers(ctx);
			ERROR(
				err,
				1,
				"Failed to initialize HW frame context."
				"Error code: %s",
				av_err2str(ret));
		}

		ctx->hw_frames_ctx = av_buffer_ref(hw_frames_ref);
		ret = av_hwframe_get_buffer(ctx->hw_frames_ctx, ctx->frame_out, 0);
		if (ret < 0)
		{
			av_buffer_unref(&hw_frames_ref);
			destroy_scalers(ctx);
			ERROR(
				err,
				1,
				"Could not allocate video hardware frame data for scaling: %s",
				av_err2str(ret));
		}
		av_buffer_unref(&hw_frames_ref);
	}

	enum AVPixelFormat pix_fmts[] = {AV_PIX_FMT_BGR0, AV_PIX_FMT_RGB0, AV_PIX_FMT_RGB24};
	ScaleContext* scalers[] = {&ctx->bgr0, &ctx->rgb0, &ctx->rgb};
	for (int i = 0; i < 3; i++)
	{
		init_scaler(
			scalers[i],
			width_in,
			height_in,
			width_out,
			height_out,
			pix_fmts[i],
			pix_fmt_out,
			hw_device_ctx,
			pix_fmt_sw_out,
			ctx->frame_out,
			0,
			err);
		if (err->code && pix_fmt_out == AV_PIX_FMT_VAAPI)
		{
			log_info(
				"GPU color conversion unavailable (%s), converting %s on the CPU instead.",
				err->error_str,
				av_get_pix_fmt_name(pix_fmts[i]));
			err->code = 0;
			init_scaler(
				scalers[i],
				width_in,
				height_in,
				width_out,
				height_out,
				pix_fmts[i],
				pix_fmt_out,
				hw_device_ctx,
				pix_fmt_sw_out,
				ctx->frame_out,
				1,
				err);
		}
		OK_OR_ABORT(err);
	}
}

void scale_frame(ScaleContext* ctx, Error* err)
{
	int ret;
	if ((ret = av_buffersrc_add_frame_flags(
				   ctx->buffersrc_scale_ctx, ctx->frame_in, AV_BUFFERSRC_FLAG_KEEP_REF) < 0))
	{
		ERROR(err, ret, "Error adding frame to buffer source: %s.", av_err2str(ret));
	}

	av_frame_unref(ctx->frame_out);

	while (1)
	{
		int ret = av_buffersink_get_frame(ctx->buffersink_scale_ctx, ctx->frame_out);
		if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
			break;
		if (ret < 0)
		{
			ERROR(err, ret, "Error reading frame from buffer sink: %s.", av_err2str(ret));
		}
	}
}

void open_video(VideoContext* ctx, Error* err)
{
	if (ctx->width_out <= 1 || ctx->height_out <= 1)
		ERROR(
			err,
			1,
			"Invalid size for video: width = %d, height = %d",
			ctx->width_out,
			ctx->height_out);

	const AVCodec* codec;
	int ret;

	avformat_alloc_output_context2(&ctx->oc, NULL, "mp4", NULL);
	if (!ctx->oc)
	{
		ERROR(err, 1, "Could not find output format mp4.");
	}

	int using_hw = 0;

#ifdef HAS_VAAPI
	char* vaapi_device = getenv("WEYLUS_VAAPI_DEVICE");

	if (ctx->try_vaapi &&
		av_hwdevice_ctx_create(
			&ctx->hw_device_ctx, AV_HWDEVICE_TYPE_VAAPI, vaapi_device, NULL, 0) == 0)
	{

		if (ctx->hw_device_ctx)
		{
			AVHWFramesConstraints* cst =
				av_hwdevice_get_hwframe_constraints(ctx->hw_device_ctx, NULL);
			if (cst)
			{
				for (enum AVPixelFormat* fmt = cst->valid_sw_formats; *fmt != AV_PIX_FMT_NONE;
					 ++fmt)
				{
					log_debug("VAAPI: valid pix_fmt: %s", av_get_pix_fmt_name(*fmt));
				}
				av_hwframe_constraints_free(&cst);
			}
		}

		codec = avcodec_find_encoder_by_name("h264_vaapi");
		if (codec)
		{
			ctx->c = avcodec_alloc_context3(codec);
			if (ctx->c)
			{
				Error err = {0};
				init_scalers(
					&ctx->scalers,
					ctx->width_in,
					ctx->height_in,
					ctx->width_out,
					ctx->height_out,
					AV_PIX_FMT_VAAPI,
					AV_PIX_FMT_NV12,
					ctx->hw_device_ctx,
					&err);
				if (err.code)
				{
					log_warn("Failed to initialize scaler: %s", err.error_str);
					avcodec_free_context(&ctx->c);
				}
				else
				{
					ctx->c->pix_fmt = AV_PIX_FMT_VAAPI;
					ctx->c->hw_frames_ctx = ctx->scalers.hw_frames_ctx;
					av_opt_set(ctx->c->priv_data, "quality", "7", 0);
					av_opt_set_int(ctx->c->priv_data, "qp", ctx->qp, 0);
					set_codec_params(ctx);

					if ((ret = avcodec_open2(ctx->c, codec, NULL) == 0))
						using_hw = 1;
					else
					{
						log_debug("Could not open codec: %s!", av_err2str(ret));
						avcodec_free_context(&ctx->c);
						av_buffer_unref(&ctx->hw_device_ctx);
						destroy_scalers(&ctx->scalers);
					}
				}
			}
		}
		else
			av_buffer_unref(&ctx->hw_device_ctx);
	}
#endif

#ifdef HAS_MEDIAFOUNDATION
	if (ctx->try_mediafoundation && !using_hw)
	{
		codec = avcodec_find_encoder_by_name("h264_mf");
		if (codec)
		{
			ctx->c = avcodec_alloc_context3(codec);
			if (ctx->c)
			{
				Error err = {0};
				init_scalers(
					&ctx->scalers,
					ctx->width_in,
					ctx->height_in,
					ctx->width_out,
					ctx->height_out,
					AV_PIX_FMT_NV12,
					AV_PIX_FMT_NV12,
					NULL,
					&err);
				if (err.code)
				{
					log_warn("Failed to initialize scaler: %s", err.error_str);
					avcodec_free_context(&ctx->c);
				}
				else
				{
					ctx->c->pix_fmt = AV_PIX_FMT_NV12;
					av_opt_set(ctx->c->priv_data, "rate_control", "ld_vbr", 0);
					av_opt_set(ctx->c->priv_data, "scenario", "display_remoting", 0);
					av_opt_set(ctx->c->priv_data, "quality", "100", 0);
					set_codec_params(ctx);
					int ret = avcodec_open2(ctx->c, codec, NULL);
					if (ret == 0)
						using_hw = 1;
					else
					{
						log_debug("Could not open codec: %s!", av_err2str(ret));
						avcodec_free_context(&ctx->c);
						destroy_scalers(&ctx->scalers);
					}
				}
			}
			else
				log_debug("Could not allocate video codec context for 'h264_mf'!");
		}
		else
			log_debug("Codec 'h264_mf' not found!");
	}
#endif

#ifdef HAS_NVENC
	if (ctx->try_nvenc && !using_hw &&
		av_hwdevice_ctx_create(&ctx->hw_device_ctx, AV_HWDEVICE_TYPE_CUDA, NULL, NULL, 0) == 0)
	{
		codec = avcodec_find_encoder_by_name("h264_nvenc");
		if (codec)
		{
			ctx->c = avcodec_alloc_context3(codec);
			if (ctx->c)
			{
				Error err = {0};
				init_scalers(
					&ctx->scalers,
					ctx->width_in,
					ctx->height_in,
					ctx->width_out,
					ctx->height_out,
					AV_PIX_FMT_CUDA,
#ifdef HAS_LIBNPP
					AV_PIX_FMT_NV12,
#else
					AV_PIX_FMT_BGR0,
#endif
					ctx->hw_device_ctx,
					&err);
				if (err.code)
				{
					log_warn("Failed to initialize scaler: %s", err.error_str);
					avcodec_free_context(&ctx->c);
				}
				else
				{
					ctx->c->pix_fmt = AV_PIX_FMT_CUDA;
					ctx->c->hw_frames_ctx = ctx->scalers.hw_frames_ctx;
					av_opt_set(ctx->c->priv_data, "preset", "p1", 0);
					av_opt_set(ctx->c->priv_data, "zerolatency", "1", 0);
					av_opt_set(ctx->c->priv_data, "tune", "ull", 0);
					av_opt_set(ctx->c->priv_data, "rc", "cbr", 0);
					av_opt_set(ctx->c->priv_data, "cq", "21", 0);
					av_opt_set(ctx->c->priv_data, "delay", "0", 0);
					set_codec_params(ctx);

					int ret = avcodec_open2(ctx->c, codec, NULL);
					if (ret == 0)
						using_hw = 1;
					else
					{
						log_debug("Could not open codec: %s!", av_err2str(ret));
						avcodec_free_context(&ctx->c);
						destroy_scalers(&ctx->scalers);
					}
				}
			}
			else
				log_debug("Could not allocate video codec context for 'h264_nvenc'!");
		}
		else
			log_debug("Codec 'h264_nvenc' not found!");
	}
#endif

#ifdef HAS_VIDEOTOOLBOX
	if (ctx->try_videotoolbox && !using_hw)
	{
		codec = avcodec_find_encoder_by_name("h264_videotoolbox");
		if (codec)
		{
			ctx->c = avcodec_alloc_context3(codec);
			if (ctx->c)
			{
				Error err = {0};
				init_scalers(
					&ctx->scalers,
					ctx->width_in,
					ctx->height_in,
					ctx->width_out,
					ctx->height_out,
					AV_PIX_FMT_YUV420P,
					AV_PIX_FMT_YUV420P,
					ctx->hw_device_ctx,
					&err);
				if (err.code)
				{
					log_warn("Failed to initialize scaler: %s", err.error_str);
					avcodec_free_context(&ctx->c);
				}
				else
				{
					ctx->c->pix_fmt = AV_PIX_FMT_YUV420P;
					av_opt_set(ctx->c->priv_data, "realtime", "true", 0);
					av_opt_set(ctx->c->priv_data, "allow_sw", "true", 0);
					av_opt_set(ctx->c->priv_data, "profile", "extended", 0);
					av_opt_set(ctx->c->priv_data, "level", "5.2", 0);
					set_codec_params(ctx);
					if (avcodec_open2(ctx->c, codec, NULL) == 0)
						using_hw = 1;
					else
					{
						log_debug("Could not open codec: %s!", av_err2str(ret));
						avcodec_free_context(&ctx->c);
						destroy_scalers(&ctx->scalers);
					}
				}
			}
		}
	}
#endif

	if (!using_hw)
	{
		codec = avcodec_find_encoder_by_name("libx264");
		if (!codec)
		{
			ERROR(err, 1, "Codec 'libx264' not found");
		}

		ctx->c = avcodec_alloc_context3(codec);
		if (!ctx->c)
		{
			ERROR(err, 1, "Could not allocate video codec context");
		}

		init_scalers(
			&ctx->scalers,
			ctx->width_in,
			ctx->height_in,
			ctx->width_out,
			ctx->height_out,
			AV_PIX_FMT_YUV420P,
			AV_PIX_FMT_YUV420P,
			NULL,
			err);
		if (err->code)
		{
			avcodec_free_context(&ctx->c);
			return;
		}

		ctx->c->pix_fmt = AV_PIX_FMT_YUV420P;
		av_opt_set(ctx->c->priv_data, "preset", "ultrafast", 0);
		av_opt_set(ctx->c->priv_data, "tune", "zerolatency", 0);
		av_opt_set_int(ctx->c->priv_data, "crf", ctx->qp, 0);
		set_codec_params(ctx);

		ret = avcodec_open2(ctx->c, codec, NULL);
		if (ret < 0)
		{
			avcodec_free_context(&ctx->c);
			ERROR(err, 1, "Could not open codec: %s", av_err2str(ret));
		}
	}

	ctx->st = avformat_new_stream(ctx->oc, NULL);
	avcodec_parameters_from_context(ctx->st->codecpar, ctx->c);

	ctx->pkt = av_packet_alloc();
	if (!ctx->pkt)
		ERROR(err, 1, "Failed to allocate packet");

	int buf_size = 1024 * 1024;
	ctx->buf = av_malloc(buf_size);
	ctx->oc->pb = avio_alloc_context(
		ctx->buf, buf_size, AVIO_FLAG_WRITE, ctx->rust_ctx, NULL, write_video_packet, NULL);
	if (!ctx->oc->pb)
		ERROR(err, 1, "Failed to allocate avio context");

	AVDictionary* opt = NULL;

	// enable writing fragmented mp4
	av_dict_set(&opt, "movflags", "frag_custom+empty_moov+default_base_moof", 0);
	ret = avformat_write_header(ctx->oc, &opt);
	if (ret < 0)
		log_warn("Video: failed to write header!");
	av_dict_free(&opt);

	if (av_pix_fmt_desc_get(ctx->c->pix_fmt)->flags & AV_PIX_FMT_FLAG_HWACCEL &&
		ctx->c->hw_frames_ctx)
	{
		const char* pix_fmt_sw =
			av_get_pix_fmt_name(((AVHWFramesContext*)ctx->c->hw_frames_ctx->data)->sw_format);
		log_info(
			"Video: %dx%d@%s pix_fmt: %s (%s)",
			ctx->width_out,
			ctx->height_out,
			ctx->c->codec->name,
			av_get_pix_fmt_name(ctx->c->pix_fmt),
			pix_fmt_sw);
	}
	else
		log_info(
			"Video: %dx%d@%s pix_fmt: %s",
			ctx->width_out,
			ctx->height_out,
			ctx->c->codec->name,
			av_get_pix_fmt_name(ctx->c->pix_fmt));

	ctx->initialized = 1;
}

void destroy_video_encoder(VideoContext* ctx)
{
	if (ctx->initialized)
	{
		av_write_trailer(ctx->oc);
		avio_context_free(&ctx->oc->pb);
		avformat_free_context(ctx->oc);
		avcodec_free_context(&ctx->c);
		av_packet_free(&ctx->pkt);
		av_free(ctx->buf);
		destroy_scalers(&ctx->scalers);
	}
	destroy_drm(&ctx->drm);
	if (ctx->hw_device_ctx)
		av_buffer_unref(&ctx->hw_device_ctx);
	free(ctx);
}

void encode_video_frame(VideoContext* ctx, int millis, Error* err)
{
	int ret;
	AVFrame* frame = ctx->frame;
	if (!frame)
		ERROR(err, 1, "Frame not initialized!");

	frame->pts = millis;

	ret = avcodec_send_frame(ctx->c, frame);
	if (ret < 0)
		ERROR(err, 1, "Error sending a frame for encoding: %s", av_err2str(ret));

	while (ret >= 0)
	{
		ret = avcodec_receive_packet(ctx->c, ctx->pkt);
		if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF)
			return;
		else if (ret < 0)
		{
			ERROR(err, 1, "Error during encoding");
		}

		av_packet_rescale_ts(ctx->pkt, ctx->c->time_base, ctx->st->time_base);
		av_write_frame(ctx->oc, ctx->pkt);
		av_packet_unref(ctx->pkt);

		// new fragment on every frame for lowest latency
		av_write_frame(ctx->oc, NULL);
	}
}

VideoContext* init_video_encoder(
	void* rust_ctx,
	int width_in,
	int height_in,
	int width_out,
	int height_out,
	int try_vaapi,
	int try_nvenc,
	int try_videotoolbox,
	int try_mediafoundation,
	int gop_size,
	int qp)
{
	VideoContext* ctx = malloc(sizeof(VideoContext));
	// 0 = keep Weylus' defaults (a keyframe every 12 frames lets browsers recover quickly)
	ctx->gop_size = gop_size > 0 ? gop_size : 12;
	ctx->qp = qp > 0 ? qp : 23;
	ctx->rust_ctx = rust_ctx;
	ctx->width_out = width_out - width_out % 2;
	ctx->height_out = height_out - height_out % 2;
	ctx->width_in = width_in;
	ctx->height_in = height_in;
	ctx->pts = 0;
	ctx->initialized = 0;
	ctx->frame_allocated = 0;
	ctx->try_vaapi = try_vaapi;
	ctx->try_nvenc = try_nvenc;
	ctx->try_videotoolbox = try_videotoolbox;
	ctx->try_mediafoundation = try_mediafoundation;
	ctx->hw_device_ctx = NULL;

	// make sure all scalers are zero initialized so that destroy can always be called
	memset(&ctx->scalers, 0, sizeof(Scalers));
	memset(&ctx->drm, 0, sizeof(DrmContext));
	return ctx;
}

void fill_bgr0(VideoContext* ctx, const void* data, int stride, Error* err)
{
	ctx->frame = NULL;
	ScaleContext* scaler = &ctx->scalers.bgr0;
	scaler->frame_in->data[0] = (uint8_t*)data;
	scaler->frame_in->linesize[0] = stride;

	scale_frame(scaler, err);
	OK_OR_ABORT(err)
	ctx->frame = scaler->frame_out;
}

void fill_rgb(VideoContext* ctx, const void* data, Error* err)
{
	ctx->frame = NULL;
	ScaleContext* scaler = &ctx->scalers.rgb;
	ctx->frame = NULL;
	scaler->frame_in->data[0] = (uint8_t*)data;
	scaler->frame_in->linesize[0] = ctx->width_in * 3;

	scale_frame(scaler, err);
	OK_OR_ABORT(err)
	ctx->frame = scaler->frame_out;
}

void fill_rgb0(VideoContext* ctx, const void* data, Error* err)
{
	ctx->frame = NULL;
	ScaleContext* scaler = &ctx->scalers.rgb0;
	scaler->frame_in->data[0] = (uint8_t*)data;
	scaler->frame_in->linesize[0] = ctx->width_in * 4;

	scale_frame(scaler, err);
	OK_OR_ABORT(err)
	ctx->frame = scaler->frame_out;
}

#ifdef HAS_VAAPI
static void free_drm_desc(void* opaque, uint8_t* data)
{
	(void)opaque;
	// The DMA-BUF fd itself belongs to the capture pipeline; only free the descriptor.
	av_free(data);
}

static void init_drm(VideoContext* ctx, uint32_t fourcc, uint64_t modifier, int width, int height, Error* err)
{
	DrmContext* d = &ctx->drm;
	int ret;
	char args[512];
	enum AVPixelFormat sw_format;

	// DRM fourccs are little-endian channel orders: XR24 = XRGB8888 = B,G,R,X in memory.
	if (fourcc == 0x34325258) // 'XR24'
		sw_format = AV_PIX_FMT_BGR0;
	else if (fourcc == 0x34324258) // 'XB24'
		sw_format = AV_PIX_FMT_RGB0;
	else if (fourcc == 0x34325241) // 'AR24'
		sw_format = AV_PIX_FMT_BGRA;
	else if (fourcc == 0x34324241) // 'AB24'
		sw_format = AV_PIX_FMT_RGBA;
	else
		ERROR(err, 1, "Unsupported DRM format 0x%08x for zero-copy capture.", fourcc);

	const char* device = getenv("WEYLUS_VAAPI_DEVICE");
	if ((ret = av_hwdevice_ctx_create(
			 &d->drm_device,
			 AV_HWDEVICE_TYPE_DRM,
			 device ? device : "/dev/dri/renderD128",
			 NULL,
			 0)) < 0)
		ERROR(err, 1, "Failed to open DRM device: %s", av_err2str(ret));

	d->drm_frames = av_hwframe_ctx_alloc(d->drm_device);
	if (!d->drm_frames)
		ERROR(err, 1, "Failed to allocate DRM frames context.");
	AVHWFramesContext* drm_fc = (AVHWFramesContext*)d->drm_frames->data;
	drm_fc->format = AV_PIX_FMT_DRM_PRIME;
	drm_fc->sw_format = sw_format;
	drm_fc->width = width;
	drm_fc->height = height;
	if ((ret = av_hwframe_ctx_init(d->drm_frames)) < 0)
		ERROR(err, 1, "Failed to init DRM frames context: %s", av_err2str(ret));

	// Imported surfaces are created per frame by av_hwframe_map, so no pool is needed.
	d->vaapi_frames = av_hwframe_ctx_alloc(ctx->hw_device_ctx);
	if (!d->vaapi_frames)
		ERROR(err, 1, "Failed to allocate VAAPI frames context.");
	AVHWFramesContext* va_fc = (AVHWFramesContext*)d->vaapi_frames->data;
	va_fc->format = AV_PIX_FMT_VAAPI;
	va_fc->sw_format = sw_format;
	va_fc->width = width;
	va_fc->height = height;
	va_fc->initial_pool_size = 0;
	if ((ret = av_hwframe_ctx_init(d->vaapi_frames)) < 0)
		ERROR(err, 1, "Failed to init VAAPI frames context: %s", av_err2str(ret));

	// Filter graph: VAAPI (RGB) -> scale_vaapi -> VAAPI (NV12, output size)
	ScaleContext* sc = &d->scale;
	sc->filter_graph_scale = avfilter_graph_alloc();
	if (!sc->filter_graph_scale)
		ERROR(err, 1, "Failed to allocate filter graph.");

	sc->buffersrc_scale_ctx =
		avfilter_graph_alloc_filter(sc->filter_graph_scale, avfilter_get_by_name("buffer"), "in");
	if (!sc->buffersrc_scale_ctx)
		ERROR(err, 1, "Failed to allocate buffer source.");
	AVBufferSrcParameters* par = av_buffersrc_parameters_alloc();
	if (!par)
		ERROR(err, 1, "Failed to allocate buffer source parameters.");
	par->format = AV_PIX_FMT_VAAPI;
	par->width = width;
	par->height = height;
	par->time_base = TIME_BASE;
	par->sample_aspect_ratio = (AVRational){1, 1};
	par->hw_frames_ctx = d->vaapi_frames;
	ret = av_buffersrc_parameters_set(sc->buffersrc_scale_ctx, par);
	av_free(par);
	if (ret < 0 || (ret = avfilter_init_dict(sc->buffersrc_scale_ctx, NULL)) < 0)
		ERROR(err, 1, "Failed to init buffer source: %s", av_err2str(ret));

	if ((ret = avfilter_graph_create_filter(
			 &sc->buffersink_scale_ctx,
			 avfilter_get_by_name("buffersink"),
			 "out",
			 NULL,
			 NULL,
			 sc->filter_graph_scale)) < 0)
		ERROR(err, 1, "Failed to create buffer sink: %s", av_err2str(ret));

	AVFilterInOut* outputs = avfilter_inout_alloc();
	AVFilterInOut* inputs = avfilter_inout_alloc();
	if (!outputs || !inputs)
	{
		avfilter_inout_free(&outputs);
		avfilter_inout_free(&inputs);
		ERROR(err, 1, "Failed to allocate filter in/outputs.");
	}
	outputs->name = av_strdup("in");
	outputs->filter_ctx = sc->buffersrc_scale_ctx;
	outputs->pad_idx = 0;
	outputs->next = NULL;
	inputs->name = av_strdup("out");
	inputs->filter_ctx = sc->buffersink_scale_ctx;
	inputs->pad_idx = 0;
	inputs->next = NULL;

	// scale_vaapi takes its device from the input frames, so no hw_device_ctx is needed here.
	snprintf(
		args,
		sizeof(args),
		"scale_vaapi=w=%d:h=%d:format=nv12:mode=fast:out_color_matrix=bt709:out_range=full:"
		"out_color_primaries=bt709:out_color_transfer=bt709",
		ctx->width_out,
		ctx->height_out);
	ret = avfilter_graph_parse_ptr(sc->filter_graph_scale, args, &inputs, &outputs, NULL);
	avfilter_inout_free(&inputs);
	avfilter_inout_free(&outputs);
	if (ret < 0)
		ERROR(err, 1, "Failed to parse zero-copy filter graph: %s", av_err2str(ret));
	if ((ret = avfilter_graph_config(sc->filter_graph_scale, NULL)) < 0)
		ERROR(err, 1, "Failed to configure zero-copy filter graph: %s", av_err2str(ret));

	sc->frame_out = av_frame_alloc();
	if (!sc->frame_out)
		ERROR(err, 1, "Failed to allocate output frame.");

	d->fourcc = fourcc;
	d->modifier = modifier;
	d->width = width;
	d->height = height;
	d->initialized = 1;
	log_info(
		"Zero-copy capture enabled: DMA-BUF %dx%d format 0x%08x modifier 0x%016llx -> VAAPI.",
		width,
		height,
		fourcc,
		(unsigned long long)modifier);
}
#endif

// Encode a frame given as a single-plane DMA-BUF. Only works when the VAAPI encoder is in use;
// callers should fall back to regular (copying) capture when this reports an error.
void fill_drm_prime(
	VideoContext* ctx,
	int fd,
	int width,
	int height,
	uint32_t fourcc,
	uint64_t modifier,
	int offset,
	int pitch,
	Error* err)
{
	ctx->frame = NULL;
#ifdef HAS_VAAPI
	int ret;
	if (!ctx->c || ctx->c->pix_fmt != AV_PIX_FMT_VAAPI || !ctx->hw_device_ctx)
		ERROR(err, 1, "Zero-copy capture needs the VAAPI encoder, which is not in use.");

	DrmContext* d = &ctx->drm;
	if (d->initialized &&
		(d->fourcc != fourcc || d->modifier != modifier || d->width != width ||
		 d->height != height))
		destroy_drm(d);
	if (!d->initialized)
	{
		init_drm(ctx, fourcc, modifier, width, height, err);
		if (err->code)
		{
			destroy_drm(d);
			return;
		}
	}

	AVDRMFrameDescriptor* desc = av_mallocz(sizeof(AVDRMFrameDescriptor));
	if (!desc)
		ERROR(err, 1, "Failed to allocate DRM frame descriptor.");
	// DMA-BUF size is reported by seeking to the end of the fd.
	off_t size = lseek(fd, 0, SEEK_END);
	lseek(fd, 0, SEEK_SET);
	desc->nb_objects = 1;
	desc->objects[0].fd = fd;
	desc->objects[0].size = size > 0 ? (size_t)size : (size_t)offset + (size_t)pitch * height;
	desc->objects[0].format_modifier = modifier;
	desc->nb_layers = 1;
	desc->layers[0].format = fourcc;
	desc->layers[0].nb_planes = 1;
	desc->layers[0].planes[0].object_index = 0;
	desc->layers[0].planes[0].offset = offset;
	desc->layers[0].planes[0].pitch = pitch;

	AVFrame* src = av_frame_alloc();
	AVFrame* mapped = av_frame_alloc();
	if (!src || !mapped)
	{
		av_free(desc);
		av_frame_free(&src);
		av_frame_free(&mapped);
		ERROR(err, 1, "Failed to allocate frames.");
	}
	src->format = AV_PIX_FMT_DRM_PRIME;
	src->width = width;
	src->height = height;
	src->data[0] = (uint8_t*)desc;
	src->buf[0] = av_buffer_create((uint8_t*)desc, sizeof(*desc), free_drm_desc, NULL, 0);
	src->hw_frames_ctx = av_buffer_ref(d->drm_frames);
	if (!src->buf[0] || !src->hw_frames_ctx)
	{
		if (!src->buf[0])
			av_free(desc);
		av_frame_free(&src);
		av_frame_free(&mapped);
		ERROR(err, 1, "Failed to wrap DMA-BUF.");
	}

	mapped->format = AV_PIX_FMT_VAAPI;
	mapped->hw_frames_ctx = av_buffer_ref(d->vaapi_frames);
	ret = av_hwframe_map(mapped, src, AV_HWFRAME_MAP_READ);
	// The mapping keeps its own reference to src.
	av_frame_free(&src);
	if (ret < 0)
	{
		av_frame_free(&mapped);
		ERROR(err, 1, "Failed to import DMA-BUF into VAAPI: %s", av_err2str(ret));
	}

	ret = av_buffersrc_add_frame_flags(d->scale.buffersrc_scale_ctx, mapped, 0);
	av_frame_free(&mapped);
	if (ret < 0)
		ERROR(err, 1, "Failed to submit frame to zero-copy filter: %s", av_err2str(ret));

	av_frame_unref(d->scale.frame_out);
	ret = av_buffersink_get_frame(d->scale.buffersink_scale_ctx, d->scale.frame_out);
	if (ret < 0)
		ERROR(err, 1, "Failed to get frame from zero-copy filter: %s", av_err2str(ret));

	// Wait until the GPU has finished reading the imported DMA-BUF, so the caller can hand it back
	// to the compositor before encoding. (A virtual monitor can only draw its next frame into a free
	// buffer, so holding it during the encode throttles the whole screen.)
	{
		AVHWDeviceContext* dev = (AVHWDeviceContext*)ctx->hw_device_ctx->data;
		AVVAAPIDeviceContext* hw = dev->hwctx;
		VASurfaceID surface = (VASurfaceID)(uintptr_t)d->scale.frame_out->data[3];
		vaSyncSurface(hw->display, surface);
	}
	ctx->frame = d->scale.frame_out;
#else
	(void)fd;
	(void)width;
	(void)height;
	(void)fourcc;
	(void)modifier;
	(void)offset;
	(void)pitch;
	ERROR(err, 1, "Zero-copy capture is only supported with VAAPI.");
#endif
}
