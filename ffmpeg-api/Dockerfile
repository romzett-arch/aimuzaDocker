FROM node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53 AS media-build
RUN apk add --no-cache build-base nasm curl xz pkgconf lame-dev opus-dev libvorbis-dev
WORKDIR /build
# Official release archive, pinned independently of the moving Alpine package.
RUN curl --fail --location --retry 3 --connect-timeout 20 --max-time 300 \
      https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz -o ffmpeg.tar.xz \
    && echo '8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e  ffmpeg.tar.xz' | sha256sum -c - \
    && tar -xf ffmpeg.tar.xz --strip-components=1 \
    && ./configure --prefix=/opt/ffmpeg --disable-autodetect --disable-everything \
      --disable-doc --disable-debug --disable-network --enable-small \
      --enable-ffmpeg --enable-ffprobe --enable-avcodec --enable-avformat --enable-avfilter --enable-swresample \
      --enable-libmp3lame --enable-libopus --enable-libvorbis \
      --enable-protocol=file,pipe \
      --enable-demuxer=mp3,wav,flac,ogg,mov,matroska,aac \
      --enable-muxer=mp3,wav,flac,ogg,mp4,ipod,matroska,webm,adts,null \
      --enable-parser=aac,aac_latm,flac,mpegaudio,opus,vorbis \
      --enable-decoder=mp3,mp3float,aac,aac_fixed,aac_latm,alac,flac,opus,vorbis,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f64le,pcm_u8 \
      --enable-encoder=libmp3lame,libopus,libvorbis,aac,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_f64le \
      --enable-filter=abuffer,abuffersink,aformat,anull,aresample,loudnorm,dynaudnorm,acompressor,alimiter,atrim,asetpts,volume \
    && make -j2 && make install \
    && mkdir -p /opt/ffmpeg/share/licenses \
    && cp COPYING.LGPLv2.1 LICENSE.md /opt/ffmpeg/share/licenses/

FROM node:24-alpine@sha256:06d7adf3e0ef61a13f1d28682726366f97a15aa1888c934d3ecec86c33918b53

RUN apk add --no-cache lame-libs opus libvorbis && apk upgrade --no-cache
COPY --from=media-build /opt/ffmpeg /opt/ffmpeg
ENV PATH=/opt/ffmpeg/bin:$PATH

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force && rm -rf /usr/local/lib/node_modules/npm /opt/yarn*

COPY server.js handlers.js utils.js duration.js safe-download.js safe-logging.js ./
RUN mkdir -p uploads output && chown -R node:node uploads output
USER node

EXPOSE 3001

CMD ["node", "server.js"]
