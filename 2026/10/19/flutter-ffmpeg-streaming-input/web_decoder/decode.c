#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <libavutil/channel_layout.h>
#include <emscripten/emscripten.h>

typedef struct {
 AVFormatContext *fmt; AVCodecContext *ac,*vc,*jpeg;
 AVPacket *packet,*jpeg_packet; AVFrame *frame,*scaled;
 SwrContext *swr;struct SwsContext *sws;
 int ai,vi,drain,eof,flushed,kind,size;
 int64_t samples,limit; double next_image,last_video,pts;
 uint8_t audio[16384];const uint8_t *output;
} Decoder;
static Decoder s;
EMSCRIPTEN_KEEPALIVE void close_decoder(void){
 swr_free(&s.swr);sws_freeContext(s.sws);avcodec_free_context(&s.jpeg);avcodec_free_context(&s.ac);avcodec_free_context(&s.vc);avformat_close_input(&s.fmt);
 av_packet_free(&s.packet);av_packet_free(&s.jpeg_packet);av_frame_free(&s.frame);av_frame_free(&s.scaled);memset(&s,0,sizeof(s));
}
EMSCRIPTEN_KEEPALIVE int open_decoder(const char *path,int seconds){
 close_decoder();s.drain=-1;s.ai=s.vi=-1;s.limit=(int64_t)seconds*16000;s.next_image=.5;s.last_video=-1;
 s.packet=av_packet_alloc();s.jpeg_packet=av_packet_alloc();s.frame=av_frame_alloc();s.scaled=av_frame_alloc();int ret;
 if((ret=avformat_open_input(&s.fmt,path,NULL,NULL))<0)return ret;
 if((ret=avformat_find_stream_info(s.fmt,NULL))<0)return ret;
 s.ai=av_find_best_stream(s.fmt,AVMEDIA_TYPE_AUDIO,-1,-1,NULL,0);s.vi=av_find_best_stream(s.fmt,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);
 if(s.ai<0||s.vi<0)return AVERROR_STREAM_NOT_FOUND;
 int ids[]={s.ai,s.vi};AVCodecContext **ctxs[]={&s.ac,&s.vc};
 for(int i=0;i<2;i++){
  AVCodecParameters *p=s.fmt->streams[ids[i]]->codecpar;const AVCodec *c=avcodec_find_decoder(p->codec_id);if(!c)return AVERROR_DECODER_NOT_FOUND;
  *ctxs[i]=avcodec_alloc_context3(c);if(!*ctxs[i])return AVERROR(ENOMEM);avcodec_parameters_to_context(*ctxs[i],p);(*ctxs[i])->thread_count=1;
  if((ret=avcodec_open2(*ctxs[i],c,NULL))<0)return ret;
 }
 AVChannelLayout mono=AV_CHANNEL_LAYOUT_MONO;
 if((ret=swr_alloc_set_opts2(&s.swr,&mono,AV_SAMPLE_FMT_S16,16000,&s.ac->ch_layout,s.ac->sample_fmt,s.ac->sample_rate,0,NULL))<0)return ret;
 if((ret=swr_init(s.swr))<0)return ret;
 const AVCodec *jc=avcodec_find_encoder(AV_CODEC_ID_MJPEG);s.jpeg=avcodec_alloc_context3(jc);if(!s.jpeg)return AVERROR(ENOMEM);
 s.jpeg->width=256;s.jpeg->height=((s.vc->height*256/s.vc->width)/2)*2;s.jpeg->pix_fmt=AV_PIX_FMT_YUVJ420P;s.jpeg->time_base=(AVRational){1,1};s.jpeg->flags|=AV_CODEC_FLAG_QSCALE;s.jpeg->global_quality=3*FF_QP2LAMBDA;
 if((ret=avcodec_open2(s.jpeg,jc,NULL))<0)return ret;
 s.scaled->format=s.jpeg->pix_fmt;s.scaled->width=s.jpeg->width;s.scaled->height=s.jpeg->height;return av_frame_get_buffer(s.scaled,32);
}
static int audio_event(int n){
 if(n<0)return n;if(n>s.limit-s.samples)n=(int)(s.limit-s.samples);if(n<=0)return -1;
 s.kind=1;s.size=n*2;s.output=s.audio;s.pts=s.samples/16000.;s.samples+=n;return 1;
}
EMSCRIPTEN_KEEPALIVE int next_event(void){
 av_packet_unref(s.jpeg_packet);
 for(;;){
  if(s.samples>=s.limit&&s.last_video>=s.limit/16000.)return 0;
  if(s.drain>=0){
   AVCodecContext *c=s.drain==0?s.ac:s.vc;int ret=avcodec_receive_frame(c,s.frame);
   if(ret==AVERROR(EAGAIN)||ret==AVERROR_EOF){s.drain=-1;continue;}
   if(ret<0)return ret;
   if(c==s.ac){
    int cap=swr_get_out_samples(s.swr,s.frame->nb_samples);if(cap>8192)return AVERROR(ENOMEM);
    uint8_t *p=s.audio;int n=swr_convert(s.swr,&p,8192,(const uint8_t**)s.frame->extended_data,s.frame->nb_samples);av_frame_unref(s.frame);
    if(n<0)return n;ret=audio_event(n);if(ret>0)return ret;
   }else{
    double t=s.frame->best_effort_timestamp*av_q2d(s.fmt->streams[s.vi]->time_base);s.last_video=t;
    if(t+1e-6>=s.next_image&&t<s.limit/16000.){
     s.sws=sws_getCachedContext(s.sws,s.frame->width,s.frame->height,s.frame->format,s.jpeg->width,s.jpeg->height,s.jpeg->pix_fmt,SWS_BILINEAR,NULL,NULL,NULL);if(!s.sws)return AVERROR(ENOMEM);
     av_frame_make_writable(s.scaled);sws_scale(s.sws,(const uint8_t *const*)s.frame->data,s.frame->linesize,0,s.frame->height,s.scaled->data,s.scaled->linesize);s.scaled->pts=(int64_t)s.next_image;s.scaled->quality=s.jpeg->global_quality;
     ret=avcodec_send_frame(s.jpeg,s.scaled);if(ret<0)return ret;ret=avcodec_receive_packet(s.jpeg,s.jpeg_packet);if(ret<0)return ret;
     s.kind=2;s.size=s.jpeg_packet->size;s.output=s.jpeg_packet->data;s.pts=t;s.next_image+=1.;av_frame_unref(s.frame);return 2;
    }
    av_frame_unref(s.frame);
   }
  }else if(!s.eof){
   int ret=av_read_frame(s.fmt,s.packet);
   if(ret==AVERROR_EOF){s.eof=1;continue;}if(ret<0)return ret;
   int which=s.packet->stream_index==s.ai?0:s.packet->stream_index==s.vi?1:-1;
   if(which>=0){ret=avcodec_send_packet(which==0?s.ac:s.vc,s.packet);if(ret<0){av_packet_unref(s.packet);return ret;}s.drain=which;}
   av_packet_unref(s.packet);
  }else if(s.flushed<2){int which=s.flushed++;int ret=avcodec_send_packet(which==0?s.ac:s.vc,NULL);if(ret<0&&ret!=AVERROR_EOF)return ret;s.drain=which;
  }else{
   uint8_t *p=s.audio;int n=swr_convert(s.swr,&p,8192,NULL,0);if(n<0)return n;int r=audio_event(n);return r>0?r:0;
  }
 }
}
EMSCRIPTEN_KEEPALIVE uintptr_t event_ptr(void){return (uintptr_t)s.output;}
EMSCRIPTEN_KEEPALIVE int event_size(void){return s.size;}
EMSCRIPTEN_KEEPALIVE double event_pts(void){return s.pts;}
EMSCRIPTEN_KEEPALIVE const char *decoder_license(void){return avcodec_license();}
EMSCRIPTEN_KEEPALIVE const char *decoder_config(void){return avcodec_configuration();}

EMSCRIPTEN_KEEPALIVE double input_bytes_read(void){return s.fmt&&s.fmt->pb?(double)s.fmt->pb->bytes_read:0.;}
