#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <libavutil/channel_layout.h>
#include <emscripten/emscripten.h>

EMSCRIPTEN_KEEPALIVE const char *decoder_license(void){return avcodec_license();}
EMSCRIPTEN_KEEPALIVE const char *decoder_config(void){return avcodec_configuration();}
// One decoder invocation per Worker instance. The caller owns cancellation
// by terminating that Worker, releasing its filesystem and WASM memory.
EMSCRIPTEN_KEEPALIVE int decode_file(void){
 AVFormatContext *fmt=NULL; AVCodecContext *ac=NULL,*vc=NULL,*jpeg=NULL;
 AVPacket *pkt=av_packet_alloc(),*jp=av_packet_alloc();AVFrame *frame=av_frame_alloc(),*out=av_frame_alloc();
 SwrContext *swr=NULL;struct SwsContext *sws=NULL;FILE *pcm=NULL,*meta=NULL;
 int err=0,a=-1,v=-1,frames=0;int64_t samples=0;double next=.5;
 if((err=avformat_open_input(&fmt,"/input.mp4",NULL,NULL))<0)goto end;
 if((err=avformat_find_stream_info(fmt,NULL))<0)goto end;
 a=av_find_best_stream(fmt,AVMEDIA_TYPE_AUDIO,-1,-1,NULL,0);v=av_find_best_stream(fmt,AVMEDIA_TYPE_VIDEO,-1,-1,NULL,0);
 int ids[2]={a,v};AVCodecContext **ctxs[2]={&ac,&vc};
 for(int i=0;i<2;i++){if(ids[i]<0)continue;AVCodecParameters *par=fmt->streams[ids[i]]->codecpar;const AVCodec *c=avcodec_find_decoder(par->codec_id);*ctxs[i]=avcodec_alloc_context3(c);avcodec_parameters_to_context(*ctxs[i],par);if((err=avcodec_open2(*ctxs[i],c,NULL))<0)goto end;}
 if(!ac||!vc){err=-100;goto end;}
 AVChannelLayout mono=AV_CHANNEL_LAYOUT_MONO;
 if((err=swr_alloc_set_opts2(&swr,&mono,AV_SAMPLE_FMT_S16,16000,&ac->ch_layout,ac->sample_fmt,ac->sample_rate,0,NULL))<0)goto end;
 if((err=swr_init(swr))<0)goto end;
 const AVCodec *jc=avcodec_find_encoder(AV_CODEC_ID_MJPEG);jpeg=avcodec_alloc_context3(jc);jpeg->width=256;jpeg->height=((vc->height*256/vc->width)/2)*2;jpeg->pix_fmt=AV_PIX_FMT_YUVJ420P;jpeg->time_base=(AVRational){1,1};jpeg->flags|=AV_CODEC_FLAG_QSCALE;jpeg->global_quality=3*FF_QP2LAMBDA;
 if((err=avcodec_open2(jpeg,jc,NULL))<0)goto end;
 out->format=jpeg->pix_fmt;out->width=jpeg->width;out->height=jpeg->height;av_frame_get_buffer(out,32);
 pcm=fopen("/audio.pcm","wb");meta=fopen("/frames.jsonl","w");
 int eof=0;
 while(!eof){
  if(av_read_frame(fmt,pkt)<0)eof=1;
  for(int k=0;k<2;k++){
   int id=ids[k];AVCodecContext *c=*ctxs[k];if(!eof&&pkt->stream_index!=id)continue;
   if(avcodec_send_packet(c,eof?NULL:pkt)<0)continue;
   while(avcodec_receive_frame(c,frame)==0){
    if(k==0){int cap=swr_get_out_samples(swr,frame->nb_samples);uint8_t *buf=av_malloc(cap*2);int n=swr_convert(swr,&buf,cap,(const uint8_t**)frame->extended_data,frame->nb_samples);if(n>0){fwrite(buf,2,n,pcm);samples+=n;}av_free(buf);}
    else{
     int64_t ts=frame->best_effort_timestamp;double t=ts==AV_NOPTS_VALUE?0:ts*av_q2d(fmt->streams[v]->time_base);
     if(t+1e-6>=next){sws=sws_getCachedContext(sws,frame->width,frame->height,frame->format,jpeg->width,jpeg->height,jpeg->pix_fmt,SWS_BILINEAR,NULL,NULL,NULL);av_frame_make_writable(out);sws_scale(sws,(const uint8_t *const*)frame->data,frame->linesize,0,frame->height,out->data,out->linesize);out->pts=frames;out->quality=jpeg->global_quality;avcodec_send_frame(jpeg,out);if(avcodec_receive_packet(jpeg,jp)==0){char name[64];snprintf(name,sizeof(name),"/frame-%03d.jpg",frames);FILE *f=fopen(name,"wb");fwrite(jp->data,1,jp->size,f);fclose(f);fprintf(meta,"{\"pts\":%.9f,\"bytes\":%d,\"file\":\"%s\"}\n",t,jp->size,name);av_packet_unref(jp);frames++;}next+=1.;}
    }
    av_frame_unref(frame);
   }
  }
  av_packet_unref(pkt);
 }
 // Drain resampling delay; otherwise the last PCM samples are lost.
 for(;;){uint8_t b[4096];uint8_t *p=b;int n=swr_convert(swr,&p,2048,NULL,0);if(n<=0)break;fwrite(b,2,n,pcm);samples+=n;}
 err=0;
end:
 if(pcm)fclose(pcm);if(meta)fclose(meta);swr_free(&swr);sws_freeContext(sws);avcodec_free_context(&jpeg);avcodec_free_context(&ac);avcodec_free_context(&vc);avformat_close_input(&fmt);av_packet_free(&pkt);av_packet_free(&jp);av_frame_free(&frame);av_frame_free(&out);return err;
}
