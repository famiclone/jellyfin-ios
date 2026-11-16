// QWebChannel-compatible bridge over WKScriptMessageHandler ("jmpBridge") for Jellyfin Desktop iOS
(function () {
    'use strict';

    function createSignal() {
        const listeners = new Set();
        return {
            connect(fn) {
                if (typeof fn === 'function') listeners.add(fn);
            },
            disconnect(fn) {
                if (typeof fn === 'function') listeners.delete(fn);
            },
            _emit(...args) {
                for (const fn of Array.from(listeners)) {
                    try {
                        fn(...args);
                    } catch (err) {
                        console.error('[jmpBridge signal error]', err);
                    }
                }
            }
        };
    }

    let nextCallbackId = 1;
    const pendingCallbacks = new Map();

    function invokeNative(component, method, args) {
        const argList = Array.from(args);
        let callback = null;
        if (argList.length > 0 && typeof argList[argList.length - 1] === 'function') {
            callback = argList.pop();
        }

        let callbackId = null;
        if (callback) {
            callbackId = nextCallbackId++;
            pendingCallbacks.set(callbackId, callback);
        }

        try {
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.jmpBridge) {
                window.webkit.messageHandlers.jmpBridge.postMessage({
                    component: component,
                    method: method,
                    args: argList,
                    callbackId: callbackId
                });
            } else if (callback) {
                pendingCallbacks.delete(callbackId);
                setTimeout(() => callback(null), 0);
            }
        } catch (err) {
            console.error('[jmpBridge postMessage failed]', component, method, err);
            if (callbackId != null) {
                pendingCallbacks.delete(callbackId);
                setTimeout(() => callback(null), 0);
            }
        }
    }

    const api = {
        player: {
            // Signals
            playing: createSignal(),
            buffering: createSignal(),
            paused: createSignal(),
            finished: createSignal(),
            canceled: createSignal(),
            error: createSignal(),
            stopped: createSignal(),
            stateChanged: createSignal(),
            videoPlaybackActive: createSignal(),
            windowVisible: createSignal(),
            updateDuration: createSignal(),
            playbackRateChanged: createSignal(),
            positionUpdate: createSignal(),
            onVideoRecangleChanged: createSignal(),
            onMetaData: createSignal(),
            bufferedRangesUpdated: createSignal(),

            // Methods
            load() { invokeNative('player', 'load', arguments); },
            queueMedia() { invokeNative('player', 'queueMedia', arguments); },
            clearQueue() { invokeNative('player', 'clearQueue', arguments); },
            seekTo() { invokeNative('player', 'seekTo', arguments); },
            stop() { invokeNative('player', 'stop', arguments); },
            streamSwitch() { invokeNative('player', 'streamSwitch', arguments); },
            pause() { invokeNative('player', 'pause', arguments); },
            play() { invokeNative('player', 'play', arguments); },
            setVolume() { invokeNative('player', 'setVolume', arguments); },
            setMuted() { invokeNative('player', 'setMuted', arguments); },
            setAudioStream() { invokeNative('player', 'setAudioStream', arguments); },
            setSubtitleStream() { invokeNative('player', 'setSubtitleStream', arguments); },
            setAudioDelay() { invokeNative('player', 'setAudioDelay', arguments); },
            setSubtitleDelay() { invokeNative('player', 'setSubtitleDelay', arguments); },
            setPlaybackRate() { invokeNative('player', 'setPlaybackRate', arguments); },
            setVideoRectangle() { invokeNative('player', 'setVideoRectangle', arguments); },
            getPosition() { invokeNative('player', 'getPosition', arguments); },
            getDuration() { invokeNative('player', 'getDuration', arguments); },
            notifyShuffleChange() { invokeNative('player', 'notifyShuffleChange', arguments); },
            notifyRepeatChange() { invokeNative('player', 'notifyRepeatChange', arguments); },
            notifyFullscreenChange() { invokeNative('player', 'notifyFullscreenChange', arguments); },
            notifyRateChange() { invokeNative('player', 'notifyRateChange', arguments); },
            notifyQueueChange() { invokeNative('player', 'notifyQueueChange', arguments); },
            notifyPlaybackStop() { invokeNative('player', 'notifyPlaybackStop', arguments); },
            notifyDurationChange() { invokeNative('player', 'notifyDurationChange', arguments); },
            notifyPlaybackState() { invokeNative('player', 'notifyPlaybackState', arguments); },
            notifyPosition() { invokeNative('player', 'notifyPosition', arguments); },
            notifySeek() { invokeNative('player', 'notifySeek', arguments); },
            notifyMetadata() { invokeNative('player', 'notifyMetadata', arguments); },
            notifyVolumeChange() { invokeNative('player', 'notifyVolumeChange', arguments); }
        },

        settings: {
            sectionValueUpdate: createSignal(),
            groupUpdate: createSignal(),

            allValues() { invokeNative('settings', 'allValues', arguments); },
            settingDescriptions() { invokeNative('settings', 'settingDescriptions', arguments); },
            orderedSections() { invokeNative('settings', 'orderedSections', arguments); },
            setValue() { invokeNative('settings', 'setValue', arguments); }
        },

        system: {
            serverConnectivityResult: createSignal(),
            pageContentReady: createSignal(),
            updateInfoEmitted: createSignal(),
            capabilitiesChanged: createSignal(),

            openExternalUrl() { invokeNative('system', 'openExternalUrl', arguments); },
            exit() { invokeNative('system', 'exit', arguments); },
            hello() { invokeNative('system', 'hello', arguments); },
            checkServerConnectivity() { invokeNative('system', 'checkServerConnectivity', arguments); },
            cancelServerConnectivity() { invokeNative('system', 'cancelServerConnectivity', arguments); },
            fetchPageForCSPWorkaround() { invokeNative('system', 'fetchPageForCSPWorkaround', arguments); },
            checkForUpdates() { invokeNative('system', 'checkForUpdates', arguments); },
            navigateToUrl() { invokeNative('system', 'navigateToUrl', arguments); },
            resetToConnectScreen() { invokeNative('system', 'resetToConnectScreen', arguments); }
        },

        window: {
            setCursorVisibility() { invokeNative('window', 'setCursorVisibility', arguments); }
        },

        input: {
            hostInput: createSignal(),
            volumeChanged: createSignal(),
            rateChanged: createSignal(),
            positionSeek: createSignal(),

            executeActions() { invokeNative('input', 'executeActions', arguments); }
        }
    };

    window.__jmpNativeBridge = {
        api: api,
        resolveCallback(callbackId, result) {
            const cb = pendingCallbacks.get(callbackId);
            if (cb) {
                pendingCallbacks.delete(callbackId);
                try {
                    cb(result);
                } catch (err) {
                    console.error('[jmpBridge callback error]', err);
                }
            }
        },
        emitSignal(component, signalName, args) {
            const comp = api[component];
            const sig = comp && comp[signalName];
            if (sig && typeof sig._emit === 'function') {
                sig._emit(...(args || []));
            }
        }
    };
})();
