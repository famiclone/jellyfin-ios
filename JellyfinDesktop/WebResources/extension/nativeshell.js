const features = [
    "filedownload",
    "displaylanguage",
    "htmlaudioautoplay",
    "htmlvideoautoplay",
    "externallinks",
    "clientsettings",
    "multiserver",
    "remotecontrol",
    "remotevideo",
    "screensaver"
];

const getPlugins = () => {
    const basePlugins = [
        'inputPlugin'
    ];

    const mpvEnabled = jmpInfo.settings?.main?.enableMPV !== false;
    if (mpvEnabled) {
        return [
            'mpvVideoPlayer',
            'mpvAudioPlayer',
            ...basePlugins
        ];
    }

    return basePlugins;
};

const plugins = getPlugins();

for (const plugin of plugins) {
    window[plugin] = () => {
        return window["_" + plugin];
    };
}

window.NativeShell = {
    openUrl(url) {
        window.api.system.openExternalUrl(url);
    },

    downloadFile(downloadInfo) {
        window.api.system.openExternalUrl(downloadInfo.url);
    },

    openClientSettings() {
        showSettingsModal();
    },

    getPlugins() {
        return plugins;
    }
};

function getDeviceProfile() {
    const CodecProfiles = [];

    const h264Conditions = [
        {
            'Condition': 'EqualsAny',
            'Property': 'VideoProfile',
            'Value': 'high|main|baseline|constrained baseline|high 10',
            'IsRequired': false
        },
        {
            'Condition': 'LessThanEqual',
            'Property': 'VideoLevel',
            'Value': '42',
            'IsRequired': false
        }
    ];

    if (jmpInfo.settings.video.force_transcode_hi10p) {
        h264Conditions[0] = {
            'Condition': 'EqualsAny',
            'Property': 'VideoProfile',
            'Value': 'high|main|baseline|constrained baseline',
            'IsRequired': false
        };
        h264Conditions.push({
            'Condition': 'LessThanEqual',
            'Property': 'VideoBitDepth',
            'Value': '8',
            'IsRequired': false
        });
    }

    CodecProfiles.push({
        'Type': 'Video',
        'Codec': 'h264',
        'Conditions': h264Conditions
    });

    if (jmpInfo.settings.video.force_transcode_dovi) {
        CodecProfiles.push({
            'Type': 'Video',
            'Conditions': [
                {
                    'Condition': 'NotEquals',
                    'Property': 'VideoRangeType',
                    'Value': 'DOVI',
                    'IsRequired': false
                }
            ]
        });
    }

    if (jmpInfo.settings.video.force_transcode_hdr) {
        CodecProfiles.push({
            'Type': 'Video',
            'Conditions': [
                {
                    'Condition': 'Equals',
                    'Property': 'VideoRangeType',
                    'Value': 'SDR',
                    'IsRequired': false
                }
            ]
        });
    }

    if (jmpInfo.settings.video.force_transcode_hi10p) {
        CodecProfiles.push({
            'Type': 'Video',
            'Conditions': [
                {
                    'Condition': 'LessThanEqual',
                    'Property': 'VideoBitDepth',
                    'Value': '8',
                    'IsRequired': false
                }
            ]
        });
    }

    if (jmpInfo.settings.video.force_transcode_4k) {
        CodecProfiles.push({
            'Type': 'Video',
            'Conditions': [
                {
                    'Condition': 'LessThanEqual',
                    'Property': 'Width',
                    'Value': '1920',
                    'IsRequired': false
                },
                {
                    'Condition': 'LessThanEqual',
                    'Property': 'Height',
                    'Value': '1080',
                    'IsRequired': false
                }
            ]
        });
    }

    const DirectPlayProfiles = [{ 'Type': 'Audio' }, { 'Type': 'Photo' }];

    if (!jmpInfo.settings.video.always_force_transcode) {
        const directVideoCodecs = ['h264', 'mpeg4', 'mpeg2video', 'vp8', 'vp9'];
        if (!jmpInfo.settings.video.force_transcode_hevc) {
            directVideoCodecs.push('hevc', 'h265');
        }
        if (!jmpInfo.settings.video.force_transcode_av1) {
            directVideoCodecs.push('av1');
        }
        DirectPlayProfiles.push({
            'Type': 'Video',
            'VideoCodec': directVideoCodecs.join(','),
            'AudioCodec': 'aac,mp3,ac3,eac3,dts,dca,flac,alac,opus,vorbis,pcm,pcm_s16le,pcm_s24le,truehd'
        });
    }

    return {
        'Name': 'Jellyfin Desktop iOS',
        'MaxStaticBitrate': 120000000,
        'MaxStreamingBitrate': 120000000,
        'MusicStreamingTranscodingBitrate': 384000,
        'TimelineOffsetSeconds': 5,
        'TranscodingProfiles': [
            { 'Type': 'Audio' },
            {
                'Container': 'ts',
                'Type': 'Video',
                'Protocol': 'hls',
                'Context': 'Streaming',
                'AudioCodec': 'aac,mp3,ac3',
                'VideoCodec': jmpInfo.settings.video.allow_transcode_to_hevc
                    ? (
                        jmpInfo.settings.video.prefer_transcode_to_h265
                            ? 'h265,hevc,h264'
                            : 'h264,h265,hevc'
                    )
                    : 'h264',
                'MaxAudioChannels': jmpInfo.settings.audio.channels === '2.0' ? '2' : '6',
                'MinSegments': 2,
                'BreakOnNonKeyFrames': false
            },
            { 'Container': 'jpeg', 'Type': 'Photo' }
        ],
        DirectPlayProfiles,
        'ResponseProfiles': [],
        'ContainerProfiles': [],
        CodecProfiles,
        'SubtitleProfiles': [
            { 'Format': 'vtt', 'Method': 'External' },
            { 'Format': 'srt', 'Method': 'External' },
            { 'Format': 'ass', 'Method': 'External' },
            { 'Format': 'ssa', 'Method': 'External' },
            { 'Format': 'sub', 'Method': 'External' },
            { 'Format': 'smi', 'Method': 'External' },
            { 'Format': 'pgssub', 'Method': 'Embed' },
            { 'Format': 'dvdsub', 'Method': 'Embed' },
            { 'Format': 'dvbsub', 'Method': 'Embed' },
            { 'Format': 'pgs', 'Method': 'Embed' }
        ]
    };
}

async function createApi() {
    return window.__jmpNativeBridge.api;
}

let rawSettings = {};
Object.assign(rawSettings, jmpInfo.settings);
try {
    const settingsFromStorage = window.sessionStorage.getItem('settings');
    if (settingsFromStorage) {
        rawSettings = JSON.parse(settingsFromStorage);
        Object.assign(jmpInfo.settings, rawSettings);
    }
} catch (e) {
    // sessionStorage unavailable on some origins
}

jmpInfo.settingsDescriptionsUpdate = [];
jmpInfo.settingsUpdate = [];
window.apiPromise = createApi();
window.initCompleted = new Promise(async (resolve) => {
    window.api = await window.apiPromise;

    const [nativeSettings, nativeDescriptions, nativeSections] = await Promise.all([
        new Promise(res => window.api.settings.allValues('', res)),
        new Promise(res => window.api.settings.settingDescriptions(res)),
        new Promise(res => window.api.settings.orderedSections(res))
    ]);

    if (nativeSettings && Object.keys(nativeSettings).length > 0) {
        rawSettings = nativeSettings;
    }

    if (Array.isArray(nativeDescriptions)) {
        const descriptions = {};
        for (const section of nativeDescriptions) {
            descriptions[section.key] = section.settings;
        }
        jmpInfo.settingsDescriptions = descriptions;
    }

    if (Array.isArray(nativeSections)) {
        jmpInfo.sections = nativeSections;
    }

    try {
        window.sessionStorage.setItem('settings', JSON.stringify(rawSettings));
        window.sessionStorage.setItem('settingsDescriptions', JSON.stringify(jmpInfo.settingsDescriptions));
    } catch (e) {}

    const settingUpdate = (section, key) => (
        (data) => new Promise(res => {
            rawSettings[section][key] = data;
            try {
                window.sessionStorage.setItem('settings', JSON.stringify(rawSettings));
            } catch (e) {}
            window.api.settings.setValue(section, key, data, res);
        })
    );

    const setSetting = (section, key) => {
        Object.defineProperty(jmpInfo.settings[section], key, {
            configurable: true,
            enumerable: true,
            set: settingUpdate(section, key),
            get: () => rawSettings[section][key]
        });
    };

    for (const settingGroup of Object.keys(rawSettings)) {
        jmpInfo.settings[settingGroup] = {};
        for (const setting of Object.keys(rawSettings[settingGroup])) {
            setSetting(settingGroup, setting);
        }
    }

    window.api.settings.sectionValueUpdate.connect((section, data) => {
        if (!rawSettings[section]) rawSettings[section] = {};
        Object.assign(rawSettings[section], data);
        for (const callback of jmpInfo.settingsUpdate) {
            try {
                callback(section, data);
            } catch (e) {
                console.error('Update handler failed:', e);
            }
        }
        try {
            window.sessionStorage.setItem('settings', JSON.stringify(rawSettings));
        } catch (e) {}
    });

    resolve();
});

window.NativeShell.AppHost = {
    init() {
        return Promise.resolve({
            deviceName: jmpInfo.deviceName,
            appName: 'Jellyfin Desktop iOS',
            appVersion: jmpInfo.version
        });
    },
    getDefaultLayout() {
        return jmpInfo.mode;
    },
    supports(command) {
        return features.includes(String(command).toLowerCase());
    },
    getDeviceProfile,
    getSyncProfile: getDeviceProfile,
    appName() {
        return 'Jellyfin Desktop iOS';
    },
    appVersion() {
        return jmpInfo.version;
    },
    deviceName() {
        return jmpInfo.deviceName;
    },
    exit() {
        window.api.system.resetToConnectScreen();
    }
};

async function showSettingsModal() {
    await window.initCompleted;

    const modalContainer = document.createElement('div');
    modalContainer.className = 'dialogContainer';
    modalContainer.style.backgroundColor = 'rgba(0,0,0,0.65)';
    modalContainer.addEventListener('click', e => {
        if (e.target == modalContainer) {
            modalContainer.remove();
        }
    });
    document.body.appendChild(modalContainer);

    const modalContainer2 = document.createElement('div');
    modalContainer2.className = 'focuscontainer dialog dialog-fixedSize dialog-small formDialog opened';
    modalContainer.appendChild(modalContainer2);

    const modalHeader = document.createElement('div');
    modalHeader.className = 'formDialogHeader';
    modalContainer2.appendChild(modalHeader);

    const title = document.createElement('h3');
    title.className = 'formDialogHeaderTitle';
    title.textContent = 'Client Settings (iPadOS)';
    modalHeader.appendChild(title);

    const modalContents = document.createElement('div');
    modalContents.className = 'formDialogContent smoothScrollY';
    modalContents.style.paddingTop = '2em';
    modalContents.style.marginBottom = '6.2em';
    modalContents.style.webkitOverflowScrolling = 'touch';
    modalContainer2.appendChild(modalContents);

    for (const sectionOrder of [...jmpInfo.sections].sort((a, b) => a.order - b.order)) {
        const section = sectionOrder.key;
        const settings = jmpInfo.settingsDescriptions[section];
        if (!settings || settings.length === 0) continue;

        const group = document.createElement('fieldset');
        group.className = 'editItemMetadataForm editMetadataForm dialog-content-centered';
        group.style.border = '0';
        group.style.outline = '0';
        modalContents.appendChild(group);

        const values = jmpInfo.settings[section];
        const legend = document.createElement('legend');
        const legendHeader = document.createElement('h2');
        legendHeader.textContent = section;
        legendHeader.style.textTransform = 'capitalize';
        legend.appendChild(legendHeader);
        group.appendChild(legend);

        for (const setting of settings) {
            const label = document.createElement('label');
            label.className = 'inputContainer';
            label.style.marginBottom = '1.6em';
            label.style.display = 'block';

            if (setting.options) {
                const safeValues = {};
                const control = document.createElement('select');
                control.className = 'emby-select-withcolor emby-select';
                for (const option of setting.options) {
                    safeValues[String(option.value)] = option.value;
                    const opt = document.createElement('option');
                    opt.value = option.value;
                    opt.selected = option.value == values[setting.key];
                    opt.appendChild(document.createTextNode(option.title));
                    control.appendChild(opt);
                }
                control.addEventListener('change', (e) => {
                    jmpInfo.settings[section][setting.key] = safeValues[e.target.value];
                });
                const labelText = document.createElement('label');
                labelText.className = 'inputLabel';
                labelText.textContent = (setting.displayName || setting.key) + ': ';
                label.appendChild(labelText);
                label.appendChild(control);
            } else {
                const control = document.createElement('input');
                control.type = 'checkbox';
                control.checked = !!values[setting.key];
                control.addEventListener('change', (e) => {
                    jmpInfo.settings[section][setting.key] = e.target.checked;
                });
                label.appendChild(control);
                label.appendChild(document.createTextNode(' ' + (setting.displayName || setting.key)));
            }

            if (setting.help) {
                const helpNote = document.createElement('div');
                helpNote.className = 'fieldDescription';
                helpNote.style.opacity = '0.7';
                helpNote.style.fontSize = '0.85em';
                helpNote.style.marginTop = '0.35em';
                helpNote.textContent = setting.help;
                label.appendChild(helpNote);
            }

            group.appendChild(label);
        }
    }

    if (jmpInfo.settings.main.userWebClient) {
        const group = document.createElement('fieldset');
        group.className = 'editItemMetadataForm editMetadataForm dialog-content-centered';
        group.style.border = '0';
        group.style.outline = '0';
        modalContents.appendChild(group);

        const legend = document.createElement('legend');
        const legendHeader = document.createElement('h2');
        legendHeader.textContent = 'Saved Server';
        legend.appendChild(legendHeader);
        group.appendChild(legend);

        const resetSavedServer = document.createElement('button');
        resetSavedServer.className = 'raised button-cancel block btnCancel emby-button';
        resetSavedServer.textContent = 'Change / Reset Saved Server';
        resetSavedServer.style.marginLeft = 'auto';
        resetSavedServer.style.marginRight = 'auto';
        resetSavedServer.style.maxWidth = '70%';
        resetSavedServer.addEventListener('click', () => {
            window.jmpInfo.settings.main.userWebClient = '';
            window.api.system.resetToConnectScreen();
        });
        group.appendChild(resetSavedServer);
    }

    const closeContainer = document.createElement('div');
    closeContainer.className = 'formDialogFooter';
    modalContents.appendChild(closeContainer);

    const close = document.createElement('button');
    close.className = 'raised button-cancel block btnCancel formDialogFooterItem emby-button';
    close.textContent = 'Close';
    close.addEventListener('click', () => {
        modalContainer.remove();
    });
    closeContainer.appendChild(close);
}
