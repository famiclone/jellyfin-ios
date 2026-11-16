let isConnecting = false;

function showError(msg) {
    const errorBox = document.getElementById('error-box');
    if (!msg) {
        errorBox.style.display = 'none';
        errorBox.textContent = '';
    } else {
        errorBox.textContent = msg;
        errorBox.style.display = 'block';
    }
}

async function tryConnect(server) {
    try {
        server = server.trim();
        if (!server.startsWith('http://') && !server.startsWith('https://')) {
            server = 'http://' + server;
        }

        console.log('Checking connectivity to:', server);
        const resolvedUrl = await window.jmpCheckServerConnectivity(server);
        console.log('Server connectivity check passed. Resolved URL:', resolvedUrl);

        window.jmpInfo.settings.main.userWebClient = server;

        if (window.api && window.api.system && window.api.system.navigateToUrl) {
            window.api.system.navigateToUrl(resolvedUrl);
        } else {
            window.location.href = resolvedUrl;
        }
        return true;
    } catch (e) {
        console.error('Server connectivity check failed:', e);
        return false;
    }
}

const updateButtonState = () => {
    const address = document.getElementById('address');
    const button = document.getElementById('connect-button');
    const hasValue = address.value.trim().length > 0;
    if (!isConnecting) {
        button.disabled = !hasValue;
    }
};

function setConnectingUI(connecting) {
    const address = document.getElementById('address');
    const title = document.getElementById('title');
    const spinner = document.getElementById('spinner');
    const button = document.getElementById('connect-button');
    const cancelBtn = document.getElementById('cancel-button');
    const sslRow = document.getElementById('ssl-toggle-row');

    isConnecting = connecting;
    if (connecting) {
        showError('');
        title.style.visibility = 'hidden';
        address.style.visibility = 'hidden';
        address.disabled = true;
        spinner.style.display = 'block';
        button.style.display = 'none';
        cancelBtn.style.display = 'block';
        sslRow.style.visibility = 'hidden';
    } else {
        title.textContent = title.getAttribute('data-original-text') || 'Connect to Server';
        title.style.visibility = 'visible';
        address.style.visibility = 'visible';
        address.disabled = false;
        spinner.style.display = 'none';
        button.style.display = 'block';
        button.style.visibility = 'visible';
        cancelBtn.style.display = 'none';
        sslRow.style.visibility = 'visible';
        updateButtonState();
    }
}

const startConnecting = async () => {
    const address = document.getElementById('address');
    const server = address.value.trim();
    if (!server) return;

    setConnectingUI(true);
    const connected = await tryConnect(server);

    if (!connected && isConnecting) {
        setConnectingUI(false);
        const failText = window.jmpConnectFailureText || "Unable to connect to the Jellyfin server. Check the IP/port (e.g. 192.168.1.100:8096) and ensure Local Network access is allowed.";
        showError(failText);
    }
};

const cancelConnection = () => {
    if (!isConnecting) return;
    isConnecting = false;
    if (window.api && window.api.system) {
        window.api.system.cancelServerConnectivity();
    }
    if (window.jmpCheckServerConnectivity && window.jmpCheckServerConnectivity.abort) {
        window.jmpCheckServerConnectivity.abort();
    }
    setConnectingUI(false);
};

document.getElementById('connect-button').addEventListener('click', (e) => {
    e.preventDefault();
    if (!e.target.disabled && !isConnecting) {
        startConnecting();
    }
});

document.getElementById('cancel-button').addEventListener('click', (e) => {
    e.preventDefault();
    cancelConnection();
});

document.getElementById('connect-form').addEventListener('submit', (e) => {
    e.preventDefault();
    if (!isConnecting) {
        startConnecting();
    }
});

document.getElementById('address').addEventListener('input', () => {
    showError('');
    updateButtonState();
});

// Localize connect screen using jellyfin-desktop's find-webclient.lang.js
function applyTranslations() {
    const fallback = {
        HeaderConnectToServer: 'Connect to Server',
        LabelServerHostHelp: '192.168.1.100:8096 or https://myserver.com',
        Connect: 'Connect',
        MessageUnableToConnectToServer: "We're unable to connect to the selected server right now. Please ensure it is running and try again."
    };
    let chosen = fallback;
    if (typeof languages !== 'undefined' && Array.isArray(languages)) {
        const navLang = (navigator.language || 'en-us').toLowerCase();
        const exact = languages.find(l => l.lang && l.lang.toLowerCase() === navLang);
        const prefix = languages.find(l => l.lang && navLang.startsWith(l.lang.toLowerCase().split('-')[0]));
        const match = exact || prefix;
        if (match) {
            chosen = {
                HeaderConnectToServer: match.HeaderConnectToServer || fallback.HeaderConnectToServer,
                LabelServerHostHelp: match.LabelServerHostHelp || fallback.LabelServerHostHelp,
                Connect: match.Connect || fallback.Connect,
                MessageUnableToConnectToServer: match.MessageUnableToConnectToServer || fallback.MessageUnableToConnectToServer
            };
        }
    }
    const title = document.getElementById('title');
    const address = document.getElementById('address');
    const button = document.getElementById('connect-button');
    title.textContent = chosen.HeaderConnectToServer;
    title.setAttribute('data-original-text', chosen.HeaderConnectToServer);
    address.placeholder = chosen.LabelServerHostHelp;
    button.textContent = chosen.Connect;
    window.jmpConnectFailureText = chosen.MessageUnableToConnectToServer;
}

applyTranslations();

(async () => {
    await window.initCompleted;

    const sslCheckbox = document.getElementById('ignore-ssl-checkbox');
    if (sslCheckbox && window.jmpInfo?.settings?.main) {
        sslCheckbox.checked = !!window.jmpInfo.settings.main.ignoreSSLErrors;
        sslCheckbox.addEventListener('change', (e) => {
            window.jmpInfo.settings.main.ignoreSSLErrors = e.target.checked;
        });
    }

    const savedServer = window.jmpInfo?.settings?.main?.userWebClient;
    if (savedServer) {
        document.getElementById('address').value = savedServer;
        setConnectingUI(true);
        const connected = await tryConnect(savedServer);
        if (!connected && isConnecting) {
            setConnectingUI(false);
            showError(window.jmpConnectFailureText);
        }
    } else {
        setConnectingUI(false);
    }
})();
