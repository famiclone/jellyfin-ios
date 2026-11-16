/* eslint-disable indent */
(function() {
    function getMediaStreamAudioTracks(mediaSource) {
        return mediaSource.MediaStreams.filter(function (s) {
            return s.Type === 'Audio';
        });
    }

    function clampVolume(val) {
        return Math.min(100, Math.max(0, Math.round(val)));
    }

    class mpvVideoPlayer {
        constructor({ events, loading, appRouter, globalize, appHost, appSettings, confirm, dashboard }) {
            this.events = events;
            this.loading = loading;
            this.appRouter = appRouter;
            this.globalize = globalize;
            this.appHost = appHost;
            this.appSettings = appSettings;
            this.confirm = confirm;

            const setBackdropFn = dashboard?.default?.setBackdropTransparency || dashboard?.setBackdropTransparency;
            this.setTransparency = setBackdropFn ? setBackdropFn.bind(dashboard?.default || dashboard) : function() {};

            this.name = 'MPV Video Player';
            this.type = 'mediaplayer';
            this.id = 'mpvvideoplayer';
            this.syncPlayWrapAs = 'htmlvideoplayer';
            this.priority = -1;
            this.useFullSubtitleUrls = true;
            this.isLocalPlayer = true;
            this.isFetching = false;

            this._videoDialog = undefined;
            this._subtitleTrackIndexToSetOnPlaying = undefined;
            this._audioTrackIndexToSetOnPlaying = undefined;
            this._showTrackOffset = undefined;
            this._currentTrackOffset = undefined;
            this._supportedFeatures = undefined;
            this._currentSrc = undefined;
            this._started = undefined;
            this._timeUpdated = undefined;
            this._currentTime = undefined;
            this._currentPlayOptions = undefined;
            this._lastProfile = undefined;
            this._duration = undefined;
            this._paused = false;
            this._volume = 100;
            this._muted = false;
            this._playRate = undefined;
            this._hasConnection = false;
            this._bufferedRanges = [];

            this.onBufferedRangesUpdated = (ranges) => {
                this._bufferedRanges = ranges;
            };

            this.onEnded = () => {
                this.onEndedInternal();
            };

            this.onTimeUpdate = (time) => {
                if (time && !this._timeUpdated) {
                    this._timeUpdated = true;
                }

                this._currentTime = time;
                this.events.trigger(this, 'timeupdate');
            };

            this.onPlaying = () => {
                if (!this._started) {
                    this._started = true;

                    this.loading.hide();

                    const volume = clampVolume(this.getSavedVolume() * 100);
                    this.setVolume(volume, false);

                    this.setPlaybackRate(this.getPlaybackRate());

                    const dlg = this._videoDialog;
                    if (dlg) {
                        dlg.style.backgroundImage = '';
                        dlg.style.backgroundColor = 'transparent';
                    }

                    document.documentElement.classList.add('jmp-video-active');

                    if (this._currentPlayOptions && this._currentPlayOptions.fullscreen) {
                        this.appRouter.showVideoOsd();
                        if (dlg) {
                            dlg.style.zIndex = 'unset';
                        }
                    }

                    window.api.player.setVideoRectangle(0, 0, 0, 0);
                }

                if (this._paused) {
                    this._paused = false;
                    this.events.trigger(this, 'unpause');
                }

                this.events.trigger(this, 'playing');
            };

            this.onPause = () => {
                this._paused = true;
                this.events.trigger(this, 'pause');
            };

            this.onWaiting = () => {
                this.events.trigger(this, 'waiting');
            };

            this.onError = async (error) => {
                this.removeMediaDialog();
                console.error(`media error: ${error}`);

                const errorData = {
                    type: 'mediadecodeerror'
                };

                try {
                    if (this.confirm) {
                        await this.confirm({
                            title: 'Playback Failed',
                            text: `Playback failed with error "${error}". Retry with server transcoding?`,
                            cancelText: 'Cancel',
                            confirmText: 'Retry'
                        });
                    }
                } catch (ex) {
                    errorData.streamInfo = {
                        mediaSource: {
                            SupportsTranscoding: false
                        }
                    };
                }

                this.events.trigger(this, 'error', [errorData]);
            };

            this.onDuration = (duration) => {
                this._duration = duration;
            };
        }

        currentSrc() {
            return this._currentSrc;
        }

        async play(options) {
            this._started = false;
            this._timeUpdated = false;
            this._currentTime = null;
            this._bufferedRanges = [];

            this.resetSubtitleOffset();
            if (options.fullscreen) {
                this.loading.show();
            }
            const elem = await this.createMediaElement(options);
            return await this.setCurrentSrc(elem, options);
        }

        getSavedVolume() {
            return this.appSettings.get('volume') || 1;
        }

        tryGetFramerate(options) {
            if (options.mediaSource && options.mediaSource.MediaStreams) {
                for (let stream of options.mediaSource.MediaStreams) {
                    if (stream.Type == 'Video') {
                        return stream.RealFrameRate || stream.AverageFrameRate || null;
                    }
                }
            }
            return null;
        }

        getStreamByIndex(mediaStreams, jellyIndex) {
            for (const stream of mediaStreams) {
                if (stream.Index == jellyIndex) {
                    return stream;
                }
            }
            return null;
        }

        getRelativeIndexByType(mediaStreams, jellyIndex, streamType) {
            let relIndex = 1;
            for (const source of mediaStreams) {
                if (source.Type != streamType || source.IsExternal) {
                    continue;
                }
                if (source.Index == jellyIndex) {
                    return relIndex;
                }
                relIndex += 1;
            }
            return null;
        }

        setCurrentSrc(elem, options) {
            return new Promise((resolve) => {
                const val = options.url;
                this._currentSrc = val;
                console.debug(`playing url: ${val}`);

                const ms = (options.playerStartPositionTicks || 0) / 10000;
                this._currentPlayOptions = options;
                this._subtitleTrackIndexToSetOnPlaying = options.mediaSource.DefaultSubtitleStreamIndex == null ? -1 : options.mediaSource.DefaultSubtitleStreamIndex;
                this._audioTrackIndexToSetOnPlaying = options.mediaSource.DefaultAudioStreamIndex;

                const streamdata = {
                    type: 'video',
                    headers: { 'User-Agent': jmpInfo.userAgent },
                    metadata: options.item,
                    media: {}
                };
                const fps = this.tryGetFramerate(options);
                if (fps) {
                    streamdata.frameRate = fps;
                }

                const player = window.api.player;
                const streams = options.mediaSource?.MediaStreams || [];

                const isTranscode = options.playMethod === 'Transcode';
                const audioRelIndex = !isTranscode && this._audioTrackIndexToSetOnPlaying != null && this._audioTrackIndexToSetOnPlaying >= 0
                    ? this.getRelativeIndexByType(streams, this._audioTrackIndexToSetOnPlaying, 'Audio')
                    : 1;

                let subtitleParam;
                if (this._subtitleTrackIndexToSetOnPlaying >= 0) {
                    const subStream = this.getStreamByIndex(streams, this._subtitleTrackIndexToSetOnPlaying);
                    if (subStream && subStream.DeliveryMethod === 'External' && subStream.DeliveryUrl) {
                        subtitleParam = '#,' + subStream.DeliveryUrl;
                    } else {
                        const relIndex = this.getRelativeIndexByType(streams, this._subtitleTrackIndexToSetOnPlaying, 'Subtitle');
                        subtitleParam = relIndex != null ? relIndex : -1;
                    }
                } else {
                    subtitleParam = -1;
                }

                player.load(
                    val,
                    { startMilliseconds: ms, autoplay: true },
                    streamdata,
                    audioRelIndex,
                    subtitleParam,
                    resolve
                );
            });
        }

        setSubtitleStreamIndex(index) {
            this._subtitleTrackIndexToSetOnPlaying = index;

            if (index < 0) {
                window.api.player.setSubtitleStream(-1);
                return;
            }

            const streams = this._currentPlayOptions?.mediaSource?.MediaStreams || [];
            const stream = this.getStreamByIndex(streams, index);

            if (stream && stream.DeliveryMethod === 'External' && stream.DeliveryUrl) {
                window.api.player.setSubtitleStream('#,' + stream.DeliveryUrl);
                return;
            }

            const relIndex = this.getRelativeIndexByType(streams, index, 'Subtitle');
            window.api.player.setSubtitleStream(relIndex != null ? relIndex : -1);
        }

        setSecondarySubtitleStreamIndex(index) {
            // Secondary subtitles not supported
        }

        resetSubtitleOffset() {
            this._currentTrackOffset = 0;
            this._showTrackOffset = false;
            window.api.player.setSubtitleDelay(0);
        }

        enableShowingSubtitleOffset() {
            this._showTrackOffset = true;
        }

        disableShowingSubtitleOffset() {
            this._showTrackOffset = false;
        }

        isShowingSubtitleOffsetEnabled() {
            return this._showTrackOffset;
        }

        setSubtitleOffset(offset) {
            const offsetValue = parseFloat(offset);
            this._currentTrackOffset = offsetValue;
            window.api.player.setSubtitleDelay(Math.round(offsetValue * 1000));
        }

        getSubtitleOffset() {
            return this._currentTrackOffset;
        }

        isAudioStreamSupported() {
            return true;
        }

        getSupportedAudioStreams() {
            const profile = this._lastProfile;
            return getMediaStreamAudioTracks(this._currentPlayOptions.mediaSource).filter((stream) => {
                return this.isAudioStreamSupported(stream, profile);
            });
        }

        setAudioStreamIndex(index) {
            this._audioTrackIndexToSetOnPlaying = index;

            const playOptions = this._currentPlayOptions;
            const streams = playOptions?.mediaSource?.MediaStreams || [];
            const isTranscode = playOptions?.playMethod === 'Transcode';
            const relIndex = index < 0 ? -1 : (isTranscode ? 1 : this.getRelativeIndexByType(streams, index, 'Audio'));
            window.api.player.setAudioStream(relIndex != null ? relIndex : -1);
        }

        onEndedInternal() {
            document.documentElement.classList.remove('jmp-video-active');

            const stopInfo = {
                src: this._currentSrc
            };

            this.events.trigger(this, 'stopped', [stopInfo]);

            this._currentTime = null;
            this._currentSrc = null;
            this._currentPlayOptions = null;
        }

        stop(destroyPlayer) {
            window.api.player.stop();

            this.onEndedInternal();

            if (destroyPlayer) {
                this.destroy();
            }
            return Promise.resolve();
        }

        removeMediaDialog() {
            document.documentElement.classList.remove('jmp-video-active');

            window.api.player.stop();
            window.api.player.setVideoRectangle(-1, 0, 0, 0);

            document.body.classList.remove('hide-scroll');

            const dlg = this._videoDialog;
            if (dlg) {
                this.setTransparency(0);
                this._videoDialog = null;
                if (dlg.parentNode) {
                    dlg.parentNode.removeChild(dlg);
                }
            }

            if (document.webkitIsFullScreen && document.webkitExitFullscreen) {
                document.webkitExitFullscreen();
            }
        }

        destroy() {
            this.removeMediaDialog();

            const player = window.api.player;
            this._hasConnection = false;
            this._bufferedRanges = [];
            player.playing.disconnect(this.onPlaying);
            player.positionUpdate.disconnect(this.onTimeUpdate);
            player.finished.disconnect(this.onEnded);
            this._duration = undefined;
            player.updateDuration.disconnect(this.onDuration);
            player.error.disconnect(this.onError);
            player.paused.disconnect(this.onPause);
            player.bufferedRangesUpdated.disconnect(this.onBufferedRangesUpdated);
        }

        createMediaElement(options) {
            let dlg = document.querySelector('.videoPlayerContainer');

            if (!dlg) {
                dlg = document.createElement('div');
                dlg.classList.add('videoPlayerContainer');
                dlg.style.position = 'fixed';
                dlg.style.top = '0';
                dlg.style.bottom = '0';
                dlg.style.left = '0';
                dlg.style.right = '0';
                dlg.style.display = 'flex';
                dlg.style.alignItems = 'center';
                dlg.style.pointerEvents = 'none';
                document.body.insertBefore(dlg, document.body.firstChild);
            }

            dlg.style.backgroundColor = 'transparent';
            if (options.fullscreen) {
                dlg.style.zIndex = '1000';
            }
            if (options.backdropUrl) {
                dlg.style.backgroundImage = `url('${options.backdropUrl}')`;
                dlg.style.backgroundSize = 'cover';
                dlg.style.backgroundPosition = 'center';
            } else {
                dlg.style.backgroundImage = '';
            }

            this.setTransparency(2);
            document.documentElement.classList.add('jmp-video-active');
            this._videoDialog = dlg;

            const player = window.api.player;
            if (!this._hasConnection) {
                this._hasConnection = true;
                player.playing.connect(this.onPlaying);
                player.positionUpdate.connect(this.onTimeUpdate);
                player.finished.connect(this.onEnded);
                player.updateDuration.connect(this.onDuration);
                player.error.connect(this.onError);
                player.paused.connect(this.onPause);
                player.bufferedRangesUpdated.connect(this.onBufferedRangesUpdated);
            }

            if (options.fullscreen) {
                document.body.classList.add('hide-scroll');
            }
            return Promise.resolve();
        }

        canPlayMediaType(mediaType) {
            return (mediaType || '').toLowerCase() === 'video';
        }

        canPlayItem(item) {
            return this.canPlayMediaType(item.MediaType);
        }

        supportsPlayMethod() {
            return true;
        }

        getDeviceProfile(item, options) {
            if (this.appHost.getDeviceProfile) {
                return this.appHost.getDeviceProfile(item, options);
            }
            return Promise.resolve({});
        }

        static getSupportedFeatures() {
            return ['PlaybackRate', 'SetAspectRatio'];
        }

        supports(feature) {
            if (!this._supportedFeatures) {
                this._supportedFeatures = mpvVideoPlayer.getSupportedFeatures();
            }
            return this._supportedFeatures.includes(feature);
        }

        isFullscreen() {
            return true;
        }

        toggleFullscreen() {}

        currentTime(val) {
            if (val != null) {
                window.api.player.seekTo(val);
                return;
            }
            return this._currentTime;
        }

        currentTimeAsync() {
            return new Promise((resolve) => {
                window.api.player.getPosition(resolve);
            });
        }

        duration() {
            return this._duration || null;
        }

        canSetAudioStreamIndex() {
            return true;
        }

        setPictureInPictureEnabled() {}
        isPictureInPictureEnabled() { return false; }
        isAirPlayEnabled() { return false; }
        setAirPlayEnabled() {}
        setBrightness() {}
        getBrightness() { return 100; }

        seekable() {
            return Boolean(this._duration);
        }

        pause() {
            window.api.player.pause();
        }

        resume() {
            this._paused = false;
            window.api.player.play();
        }

        unpause() {
            window.api.player.play();
        }

        paused() {
            return this._paused;
        }

        setPlaybackRate(value) {
            const playSpeed = +value;
            this._playRate = playSpeed;
            window.api.player.setPlaybackRate(Math.round(playSpeed * 1000));
            if (window.api && window.api.player) {
                window.api.player.notifyRateChange(playSpeed);
            }
        }

        getPlaybackRate() {
            if (!this._playRate) {
                const playRate = window.jmpInfo?.settings?.video?.default_playback_speed || 1;
                this._playRate = playRate;
            }
            return this._playRate;
        }

        getSupportedPlaybackRates() {
            return [
                { name: '0.5x', id: 0.5 },
                { name: '0.75x', id: 0.75 },
                { name: '1x', id: 1.0 },
                { name: '1.25x', id: 1.25 },
                { name: '1.5x', id: 1.5 },
                { name: '1.75x', id: 1.75 },
                { name: '2x', id: 2.0 },
                { name: '2.5x', id: 2.5 },
                { name: '3x', id: 3.0 },
                { name: '3.5x', id: 3.5 },
                { name: '4.0x', id: 4.0 }
            ];
        }

        saveVolume(value) {
            if (value) {
                this.appSettings.set('volume', value);
            }
        }

        setVolume(val, save = true) {
            val = Number(val);
            if (!isNaN(val)) {
                val = clampVolume(val);
                this._volume = val;
                if (save) {
                    this.saveVolume(val / 100);
                    this.events.trigger(this, 'volumechange');
                }
                window.api.player.setVolume(val);
            }
        }

        getVolume() {
            return clampVolume(this._volume ?? 100);
        }

        volumeUp() {
            this.setVolume(Math.min(this.getVolume() + 5, 100));
        }

        volumeDown() {
            this.setVolume(Math.max(this.getVolume() - 5, 0));
        }

        setMute(mute, triggerEvent = true) {
            this._muted = mute;
            window.api.player.setMuted(mute);
            if (triggerEvent) {
                this.events.trigger(this, 'volumechange');
            }
        }

        isMuted() {
            return this._muted;
        }

        togglePictureInPicture() {}
        toggleAirPlay() {}

        getBufferedRanges() {
            return this._bufferedRanges;
        }

        getStats() {
            const playOptions = this._currentPlayOptions;
            if (!playOptions) {
                return Promise.resolve({ categories: [] });
            }

            const categories = [];
            const mediaCategory = { stats: [], type: 'media' };
            categories.push(mediaCategory);

            if (playOptions.url) {
                let link = document.createElement('a');
                link.setAttribute('href', playOptions.url);
                const protocol = (link.protocol || '').replace(':', '');
                if (protocol) {
                    mediaCategory.stats.push({
                        label: this.globalize.translate('LabelProtocol'),
                        value: protocol
                    });
                }
                link = null;
            }

            mediaCategory.stats.push({
                label: this.globalize.translate('LabelStreamType'),
                value: 'Video (MobileVLCKit Direct Play)'
            });

            return Promise.resolve({ categories });
        }

        getSupportedAspectRatios() {
            const videoSettings = window.jmpInfo?.settingsDescriptions?.video || [];
            const aspectSetting = videoSettings.find(x => x.key == 'aspect');
            const options = aspectSetting ? aspectSetting.options : [
                { value: 'normal', title: 'Normal' },
                { value: 'zoom', title: 'Zoom' },
                { value: 'stretch', title: 'Stretch' },
                { value: 'force_4_3', title: 'Force 4:3' },
                { value: 'force_16_9', title: 'Force 16:9' }
            ];
            const current = window.jmpInfo?.settings?.video?.aspect || 'normal';

            return options.map(x => ({
                id: x.value,
                name: x.title,
                selected: x.value == current
            }));
        }

        getAspectRatio() {
            return window.jmpInfo?.settings?.video?.aspect || 'normal';
        }

        setAspectRatio(value) {
            window.jmpInfo.settings.video.aspect = value;
        }
    }

    window._mpvVideoPlayer = mpvVideoPlayer;
})();
