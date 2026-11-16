// Polyfills for iPadOS 15.8.8 (Safari 15.6 WebKit) compatibility with modern jellyfin-web (10.9/10.10/10.11+)
(function () {
    'use strict';

    if (!Array.prototype.toSorted) {
        Object.defineProperty(Array.prototype, 'toSorted', {
            value: function (compareFn) {
                return Array.prototype.slice.call(this).sort(compareFn);
            },
            configurable: true,
            writable: true
        });
    }

    if (!Array.prototype.toReversed) {
        Object.defineProperty(Array.prototype, 'toReversed', {
            value: function () {
                return Array.prototype.slice.call(this).reverse();
            },
            configurable: true,
            writable: true
        });
    }

    if (!Array.prototype.toSpliced) {
        Object.defineProperty(Array.prototype, 'toSpliced', {
            value: function (start, deleteCount) {
                var copy = Array.prototype.slice.call(this);
                var args = Array.prototype.slice.call(arguments);
                Array.prototype.splice.apply(copy, args);
                return copy;
            },
            configurable: true,
            writable: true
        });
    }

    if (!Array.prototype.with) {
        Object.defineProperty(Array.prototype, 'with', {
            value: function (index, value) {
                var copy = Array.prototype.slice.call(this);
                var len = copy.length;
                var idx = Number(index);
                if (idx < 0) idx = len + idx;
                if (idx < 0 || idx >= len) throw new RangeError('Invalid index');
                copy[idx] = value;
                return copy;
            },
            configurable: true,
            writable: true
        });
    }

    if (!Array.prototype.findLast) {
        Object.defineProperty(Array.prototype, 'findLast', {
            value: function (predicate, thisArg) {
                for (var i = this.length - 1; i >= 0; i--) {
                    if (predicate.call(thisArg, this[i], i, this)) return this[i];
                }
                return undefined;
            },
            configurable: true,
            writable: true
        });
    }

    if (!Array.prototype.findLastIndex) {
        Object.defineProperty(Array.prototype, 'findLastIndex', {
            value: function (predicate, thisArg) {
                for (var i = this.length - 1; i >= 0; i--) {
                    if (predicate.call(thisArg, this[i], i, this)) return i;
                }
                return -1;
            },
            configurable: true,
            writable: true
        });
    }

    if (!Object.hasOwn) {
        Object.hasOwn = function (obj, prop) {
            return Object.prototype.hasOwnProperty.call(obj, prop);
        };
    }

    if (!Object.groupBy) {
        Object.groupBy = function (items, callbackFn) {
            var obj = Object.create(null);
            var idx = 0;
            for (var item of items) {
                var key = callbackFn(item, idx++);
                if (!(key in obj)) obj[key] = [];
                obj[key].push(item);
            }
            return obj;
        };
    }

    if (typeof Map !== 'undefined' && !Map.groupBy) {
        Map.groupBy = function (items, callbackFn) {
            var map = new Map();
            var idx = 0;
            for (var item of items) {
                var key = callbackFn(item, idx++);
                if (!map.has(key)) map.set(key, []);
                map.get(key).push(item);
            }
            return map;
        };
    }

    if (!Promise.withResolvers) {
        Promise.withResolvers = function () {
            var resolve, reject;
            var promise = new Promise(function (res, rej) {
                resolve = res;
                reject = rej;
            });
            return { promise: promise, resolve: resolve, reject: reject };
        };
    }

    if (typeof AbortSignal !== 'undefined' && !AbortSignal.timeout) {
        AbortSignal.timeout = function (ms) {
            var controller = new AbortController();
            setTimeout(function () {
                controller.abort(new DOMException('TimeoutError', 'TimeoutError'));
            }, ms);
            return controller.signal;
        };
    }

    // Ensure transparent HTML/body rule is ready when native VLC video renders behind WKWebView
    function injectTransparencyStyle() {
        if (document.getElementById('jmp-ios-transparency-style')) return;
        var style = document.createElement('style');
        style.id = 'jmp-ios-transparency-style';
        style.textContent = [
            'html.jmp-video-active, html.jmp-video-active body {',
            '  background: transparent !important;',
            '  background-color: transparent !important;',
            '}',
            'html.jmp-video-active .backgroundContainer,',
            'html.jmp-video-active .backdropContainer {',
            '  display: none !important;',
            '  background: transparent !important;',
            '}'
        ].join('\n');
        (document.head || document.documentElement).appendChild(style);
    }

    if (document.documentElement) {
        injectTransparencyStyle();
    } else {
        document.addEventListener('DOMContentLoaded', injectTransparencyStyle, { once: true });
    }
})();
