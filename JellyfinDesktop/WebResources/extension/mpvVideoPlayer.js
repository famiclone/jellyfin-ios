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

    function sanitizeCueText(raw) {
        if (!raw) return '';
        return String(raw)
            .replace(/\{\\[^}]*\}/g, '')          // Strip ASS/SSA override tags like {\an8\pos(...)}
            .replace(/\\N/g, '\n')
            .replace(/\\n/g, '\n')
            .replace(/\\h/g, ' ')
            .replace(/\r\n/g, '\n')
            .replace(/<br\s*\/?>/gi, '\n')
            .replace(/<\/?[a-z][^>]*>/gi, '')     // Strip HTML tags safely (rendered via textContent)
            .trim();
    }

    function parseTimestampToMs(ts) {
        const clean = String(ts).trim().replace(',', '.');
        const parts = clean.split(':');
        if (parts.length === 3) {
            const h = parseFloat(parts[0]) || 0;
            const m = parseFloat(parts[1]) || 0;
            const s = parseFloat(parts[2]) || 0;
            return Math.round((h * 3600 + m * 60 + s) * 1000);
        }
        if (parts.length === 2) {
            const m = parseFloat(parts[0]) || 0;
            const s = parseFloat(parts[1]) || 0;
            return Math.round((m * 60 + s) * 1000);
        }
        return 0;
    }

    function parseSubtitlePayload(text) {
        if (!text) return [];
        const trimmed = text.trim();

        // 1. Jellyfin Stream.js JSON TrackEvents format
        if (trimmed.startsWith('{')) {
            try {
                const json = JSON.parse(trimmed);
                if (Array.isArray(json.TrackEvents)) {
                    return json.TrackEvents.map(ev => ({
                        startMs: Math.round((ev.StartPositionTicks || 0) / 10000),
                        endMs: Math.round((ev.EndPositionTicks || 0) / 10000),
                        text: sanitizeCueText(ev.Text)
                    })).filter(c => c.text && c.endMs > c.startMs)
                      .sort((a, b) => a.startMs - b.startMs);
                }
            } catch (e) {
                // Fall through to text parsers
            }
        }

        // 2. ASS / SSA format
        if (/\[Events\]/i.test(trimmed) && /^Dialogue:/m.test(trimmed)) {
            const lines = trimmed.split(/\r?\n/);
            let startIdx = 1, endIdx = 2, textIdx = 9;
            let inEvents = false;
            const cues = [];

            for (const line of lines) {
                const l = line.trim();
                if (/^\[Events\]/i.test(l)) {
                    inEvents = true;
                    continue;
                }
                if (inEvents && l.startsWith('[')) {
                    inEvents = false;
                    continue;
                }
                if (inEvents && /^Format:/i.test(l)) {
                    const cols = l.substring(7).split(',').map(c => c.trim().toLowerCase());
                    const s = cols.indexOf('start');
                    const e = cols.indexOf('end');
                    const t = cols.indexOf('text');
                    if (s >= 0) startIdx = s;
                    if (e >= 0) endIdx = e;
                    if (t >= 0) textIdx = t;
                    continue;
                }
                if (/^Dialogue:/i.test(l)) {
                    const rest = l.substring(9);
                    const fields = [];
                    let pos = 0;
                    for (let k = 0; k < textIdx; k++) {
                        const comma = rest.indexOf(',', pos);
                        if (comma === -1) break;
                        fields.push(rest.substring(pos, comma).trim());
                        pos = comma + 1;
                    }
                    fields.push(rest.substring(pos));
                    if (fields.length > textIdx) {
                        const startMs = parseTimestampToMs(fields[startIdx]);
                        const endMs = parseTimestampToMs(fields[endIdx]);
                        const cleaned = sanitizeCueText(fields[textIdx]);
                        if (cleaned && endMs > startMs) {
                            cues.push({ startMs, endMs, text: cleaned });
                        }
                    }
                }
            }
            return cues.sort((a, b) => a.startMs - b.startMs);
        }

        // 3. SRT / WebVTT format
        const blocks = trimmed.replace(/^\uFEFF/, '').split(/\r?\n\r?\n+/);
        const cues = [];
        const arrowRe = /((?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3})/;

        for (const block of blocks) {
            const lines = block.split(/\r?\n/);
            let timingIdx = -1;
            let match = null;
            for (let i = 0; i < lines.length; i++) {
                match = arrowRe.exec(lines[i]);
                if (match) {
                    timingIdx = i;
                    break;
                }
            }
            if (timingIdx >= 0 && match) {
                const startMs = parseTimestampToMs(match[1]);
                const endMs = parseTimestampToMs(match[2]);
                const body = sanitizeCueText(lines.slice(timingIdx + 1).join('\n'));
                if (body && endMs > startMs) {
                    cues.push({ startMs, endMs, text: body });
                }
            }
        }
        return cues.sort((a, b) => a.startMs - b.startMs);
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
            this._subtitleOverlay = null;
            this._subtitleCueBox = null;
            this._subtitleCues = [];
            this._subtitleFetchToken = 0;
            this._lastRenderedSubText = '';

            this._subtitleTrackIndexToSetOnPlaying = undefined;
            this._audioTrackIndexToSetOnPlaying = undefined;
            this._showTrackOffset = undefined;
            this._currentTrackOffset = 0;
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
                this._renderActiveSubtitles(time);
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

        // MARK: - WebKit Retina Subtitle Overlay

        _ensureSubtitleOverlay() {
            if (!this._subtitleOverlay || !this._subtitleOverlay.parentNode) {
                let existing = document.querySelector('.jmp-subtitle-overlay');
                if (!existing) {
                    existing = document.createElement('div');
                    existing.className = 'jmp-subtitle-overlay';
                    const cueBox = document.createElement('div');
                    cueBox.className = 'jmp-subtitle-cue';
                    cueBox.style.display = 'none';
                    existing.appendChild(cueBox);
                    document.body.appendChild(existing);
                }
                this._subtitleOverlay = existing;
                this._subtitleCueBox = existing.querySelector('.jmp-subtitle-cue');
            }
        }

        _clearSubtitles() {
            this._subtitleFetchToken++;
            this._subtitleCues = [];
            this._lastRenderedSubText = '';
            if (this._subtitleCueBox) {
                this._subtitleCueBox.textContent = '';
                this._subtitleCueBox.style.display = 'none';
            }
        }

        _removeSubtitleOverlay() {
            this._clearSubtitles();
            if (this._subtitleOverlay && this._subtitleOverlay.parentNode) {
                this._subtitleOverlay.parentNode.removeChild(this._subtitleOverlay);
            }
            this._subtitleOverlay = null;
            this._subtitleCueBox = null;
        }

        _renderActiveSubtitles(timeMs) {
            if (!this._subtitleCues || this._subtitleCues.length === 0 || timeMs == null) {
                if (this._lastRenderedSubText !== '') {
                    this._lastRenderedSubText = '';
                    if (this._subtitleCueBox) {
                        this._subtitleCueBox.textContent = '';
                        this._subtitleCueBox.style.display = 'none';
                    }
                }
                return;
            }

            this._ensureSubtitleOverlay();
            const delayMs = Math.round((this._currentTrackOffset || 0) * 1000);
            const targetMs = timeMs - delayMs;

            const activeTexts = [];
            const seen = new Set();
            for (let i = 0; i < this._subtitleCues.length; i++) {
                const cue = this._subtitleCues[i];
                if (cue.startMs > targetMs) break;
                if (targetMs >= cue.startMs && targetMs <= cue.endMs) {
                    if (!seen.has(cue.text)) {
                        seen.add(cue.text);
                        activeTexts.push(cue.text);
                    }
                }
            }

            const combined = activeTexts.join('\n');
            if (combined !== this._lastRenderedSubText) {
                this._lastRenderedSubText = combined;
                if (this._subtitleCueBox) {
                    if (combined) {
                        this._subtitleCueBox.textContent = combined;
                        this._subtitleCueBox.style.display = 'inline-block';
                    } else {
                        this._subtitleCueBox.textContent = '';
                        this._subtitleCueBox.style.display = 'none';
                    }
                }
            }
        }

        async _loadWebSubtitlesForStream(index) {
            this._clearSubtitles();
            if (index == null || index < 0) {
                window.api.player.setSubtitleStream(-1);
                return;
            }

            const playOptions = this._currentPlayOptions;
            const streams = playOptions?.mediaSource?.MediaStreams || [];
            const stream = this.getStreamByIndex(streams, index);
            if (!stream) {
                window.api.player.setSubtitleStream(-1);
                return;
            }

            const codec = String(stream.Codec || '').toLowerCase();
            const isBitmap = ['pgssub', 'pgs', 'dvdsub', 'dvbsub', 'vobsub'].includes(codec);
            if (isBitmap && !stream.IsExternal) {
                const relIndex = this.getRelativeIndexByType(streams, index, 'Subtitle');
                window.api.player.setSubtitleStream(relIndex != null ? relIndex : -1);
                return;
            }

            // Disable native libVLC text renderer and render crisply in WebKit overlay
            window.api.player.setSubtitleStream(-1);
            this._ensureSubtitleOverlay();

            const fetchToken = ++this._subtitleFetchToken;

            let serverOrigin = window.location.origin;
            let apiKey = null;
            try {
                const parsedMediaUrl = new URL(playOptions.url, window.location.href);
                serverOrigin = parsedMediaUrl.origin;
                apiKey = parsedMediaUrl.searchParams.get('api_key') || parsedMediaUrl.searchParams.get('ApiKey');
            } catch (e) {}

            if (!apiKey && window.ApiClient && typeof window.ApiClient.accessToken === 'function') {
                apiKey = window.ApiClient.accessToken();
            }

            const itemId = playOptions?.item?.Id;
            const mediaSourceId = playOptions?.mediaSource?.Id;
            const candidateUrls = [];

            if (itemId && mediaSourceId) {
                const q = apiKey ? `?api_key=${encodeURIComponent(apiKey)}` : '';
                candidateUrls.push(`${serverOrigin}/Videos/${itemId}/${mediaSourceId}/Subtitles/${index}/0/Stream.js${q}`);
            }

            if (stream.DeliveryUrl) {
                try {
                    const resolved = new URL(stream.DeliveryUrl, serverOrigin);
                    if (apiKey && !resolved.searchParams.has('api_key') && !resolved.searchParams.has('ApiKey')) {
                        resolved.searchParams.set('api_key', apiKey);
                    }
                    candidateUrls.push(resolved.href);
                } catch (e) {}
            }

            if (itemId && mediaSourceId) {
                const q = apiKey ? `?api_key=${encodeURIComponent(apiKey)}` : '';
                candidateUrls.push(`${serverOrigin}/Videos/${itemId}/${mediaSourceId}/Subtitles/${index}/0/Stream.vtt${q}`);
                candidateUrls.push(`${serverOrigin}/Videos/${itemId}/${mediaSourceId}/Subtitles/${index}/0/Stream.srt${q}`);
            }

            const headers = {};
            if (apiKey) {
                headers['X-Emby-Token'] = apiKey;
            }

            for (const subUrl of candidateUrls) {
                if (fetchToken !== this._subtitleFetchToken) return;
                try {
                    const resp = await fetch(subUrl, { credentials: 'include', headers });
                    if (!resp.ok) continue;
                    const body = await resp.text();
                    if (fetchToken !== this._subtitleFetchToken) return;
                    const cues = parseSubtitlePayload(body);
                    if (cues.length > 0) {
                        this._subtitleCues = cues;
                        console.log(`[Subtitles] Loaded ${cues.length} cues from ${subUrl}`);
                        if (this._currentTime != null) {
                            this._renderActiveSubtitles(this._currentTime);
                        }
                        return;
                    }
                } catch (err) {
                    console.warn('[Subtitles] Failed candidate URL:', subUrl, err);
                }
            }
        }

        currentSrc() {
            return this._currentSrc;
        }

        async play(options) {
            this._started = false;
            this._timeUpdated = false;
            this._currentTime = null;
            this._bufferedRanges = [];
            this._clearSubtitles();

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

                // Check if initial subtitle is bitmap or text
                let nativeSubtitleParam = -1;
                if (this._subtitleTrackIndexToSetOnPlaying >= 0) {
                    const subStream = this.getStreamByIndex(streams, this._subtitleTrackIndexToSetOnPlaying);
                    const subCodec = String(subStream?.Codec || '').toLowerCase();
                    const isBitmap = ['pgssub', 'pgs', 'dvdsub', 'dvbsub', 'vobsub'].includes(subCodec);
                    if (isBitmap && !subStream?.IsExternal) {
                        const relIndex = this.getRelativeIndexByType(streams, this._subtitleTrackIndexToSetOnPlaying, 'Subtitle');
                        nativeSubtitleParam = relIndex != null ? relIndex : -1;
                    }
                }

                player.load(
                    val,
                    { startMilliseconds: ms, autoplay: true },
                    streamdata,
                    audioRelIndex,
                    nativeSubtitleParam,
                    resolve
                );

                if (this._subtitleTrackIndexToSetOnPlaying >= 0) {
                    this._loadWebSubtitlesForStream(this._subtitleTrackIndexToSetOnPlaying);
                }
            });
        }

        setSubtitleStreamIndex(index) {
            this._subtitleTrackIndexToSetOnPlaying = index;
            this._loadWebSubtitlesForStream(index);
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
            const offsetValue = parseFloat(offset) || 0;
            this._currentTrackOffset = offsetValue;
            window.api.player.setSubtitleDelay(Math.round(offsetValue * 1000));
            if (this._currentTime != null) {
                this._renderActiveSubtitles(this._currentTime);
            }
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
            this._removeSubtitleOverlay();

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
            this._removeSubtitleOverlay();

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
            this._ensureSubtitleOverlay();

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
                this._currentTime = val;
                this._renderActiveSubtitles(val);
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
                value: playOptions.playMethod === 'Transcode' ? 'Video (AVPlayer Native HLS)' : 'Video (Direct Play)'
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
