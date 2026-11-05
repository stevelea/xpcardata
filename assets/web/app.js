/*
 * XPCarData — embedded web UI
 * ---------------------------------------------------------------------------
 * Served by the XPCarData Android app (lib/services/web_server_service.dart).
 * Single file, no dependencies, no build step, no external requests.
 *
 * Endpoints used (same origin only):
 *   GET /api/state        — server info + latest vehicle frame (polled 2 s)
 *   GET /api/sessions     — charging sessions (polled only on #/charging)
 *   GET /api/logs         — debug log tail (polled only on #/logs)
 *   GET /api/settings     — redacted app settings (polled 10 s on #/settings)
 *   GET /api/fleet        — anonymous fleet aggregates (once per #/settings open)
 *   GET /api/manual       — bundled markdown manual (loaded on #/manual)
 *
 * Authentication: when the server has a token configured it answers 401 with
 * {"error":"unauthorized","authRequired":true}. The token captured from the
 * modal is stored in localStorage["xpcd_token"] and sent as the "x-token"
 * header on every API request. It is never put in a URL.
 */
(function () {
  'use strict';

  /* ================================================================== *
   * Constants
   * ================================================================== */

  var TOKEN_KEY = 'xpcd_token';
  var POLL_STATE_MS = 2000;
  var POLL_SESSIONS_MS = 5000;
  var POLL_LOGS_MS = 3000;
  var POLL_SETTINGS_MS = 10000;
  var HISTORY_MAX = 120;
  var AUTH_MUTE_MS = 60000;
  var DASH = '\u2014';
  var PAGES = ['dashboard', 'live', 'charging', 'logs', 'settings', 'manual', 'about'];
  var PAGE_TITLES = {
    dashboard: 'Dashboard',
    live: 'Live data',
    charging: 'Charging',
    logs: 'Logs',
    settings: 'Settings',
    manual: 'Manual',
    about: 'About'
  };
  var SOURCE_LABELS = {
    obd: 'OBD-II',
    carinfo: 'CarInfo',
    mock: 'Mock data',
    proxy: 'OBD proxy',
    none: 'No source'
  };
  var MODEL_LABELS = {
    G6: 'G6',
    G6_24LR: 'G6 2024 LR/AWD',
    G6_24SR: 'G6 2024 SR',
    G6_25LR: 'G6 2025 LR/AWD',
    G6_25SR: 'G6 2025 SR',
    G9_LR_AWD: 'G9 LR/AWD',
    G9_LR_RWD: 'G9 LR/RWD',
    G9_SR_RWD: 'G9 SR/RWD',
    P7_LR_RWD: 'P7 LR/RWD',
    G3i_SR_RWD: 'G3i SR/RWD',
    CUSTOM: 'Custom'
  };
  var LEGACY_MODEL_LABELS = {
    '24LR': 'G6 2024 LR/AWD',
    '24SR': 'G6 2024 SR',
    '25LR': 'G6 2025 LR/AWD',
    '25SR': 'G6 2025 SR'
  };
  var VOLTAGE_RE = /(voltage|(^|_)v($|_))/i;

  var ICON = {
    gauge: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M4 18a8 8 0 1 1 16 0"/><path d="M12 13.5 15.5 9"/></svg>',
    battery: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="2.5" y="7" width="16" height="10" rx="3"/><path d="M21.5 10.5v3"/></svg>',
    plug: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M9 3v5M15 3v5"/><path d="M6 8h12v3a6 6 0 0 1-12 0z"/><path d="M12 17v4"/></svg>',
    grid: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>',
    thermometer: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M10 13.5V5a2 2 0 1 1 4 0v8.5a4.5 4.5 0 1 1-4 0z"/><path d="M12 12v4"/></svg>',
    motor: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><circle cx="12" cy="12" r="6.5"/><path d="M12 5.5v13M5.5 12h13"/></svg>',
    pedal: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 19 19 5"/><path d="M5 9V5h4"/><path d="M19 15v4h-4"/></svg>',
    activity: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M3 12h4l3-7 4 14 3-7h4"/></svg>',
    gps: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 21s6-5.2 6-10a6 6 0 1 0-12 0c0 4.8 6 10 6 10z"/><circle cx="12" cy="11" r="2.5"/></svg>',
    car: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M4 16h16l-1.5-5.5a2 2 0 0 0-2-1.5H7.5a2 2 0 0 0-2 1.5z"/><circle cx="7.5" cy="18" r="1.5"/><circle cx="16.5" cy="18" r="1.5"/></svg>',
    settings: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M4 7h16M4 17h16"/><circle cx="9" cy="7" r="2.5"/><circle cx="15" cy="17" r="2.5"/></svg>',
    book: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 5.5C10.5 4.5 8.5 4 6 4H4v14h2c2.5 0 4.5.5 6 1.5M12 5.5C13.5 4.5 15.5 4 18 4h2v14h-2c-2.5 0-4.5.5-6 1.5M12 5.5v14"/></svg>',
    cloud: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M7.5 18h9a4 4 0 0 0 .6-8 6 6 0 0 0-11.4 1.3A3.5 3.5 0 0 0 7.5 18z"/></svg>',
    shield: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 3 5.5 5.7v5.6c0 4.2 3 7.5 6.5 8.7 3.5-1.2 6.5-4.5 6.5-8.7V5.7z"/><path d="m9.5 11.5 1.8 1.8 3.4-3.6"/></svg>',
    wifi: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M3.5 9a13 13 0 0 1 17 0M6.5 12.5a8.5 8.5 0 0 1 11 0M9.8 16a4.5 4.5 0 0 1 4.4 0"/><circle cx="12" cy="19" r="1"/></svg>',
    route: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M5 19h6a3 3 0 0 0 0-6H9a3 3 0 0 1 0-6h10"/><circle cx="4" cy="19" r="1.6"/><circle cx="20" cy="7" r="1.6"/></svg>',
    globe: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><circle cx="12" cy="12" r="9"/><path d="M3.5 12h17M12 3.5c2.5 2.4 2.5 14.6 0 17M12 3.5c-2.5 2.4-2.5 14.6 0 17"/></svg>',
    vpn: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M12 3 5.5 5.7v5.6c0 4.2 3 7.5 6.5 8.7 3.5-1.2 6.5-4.5 6.5-8.7V5.7z"/><path d="M9.5 12h5M12 9.5v5"/></svg>',
    bluetooth: '<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="m7 7 10 10-5 4V3l5 4L7 17"/></svg>'
  };

  /* ================================================================== *
   * Tiny helpers
   * ================================================================== */

  function $(selector, root) {
    return (root || document).querySelector(selector);
  }

  function $$(selector, root) {
    return Array.prototype.slice.call((root || document).querySelectorAll(selector));
  }

  function isNum(value) {
    return typeof value === 'number' && isFinite(value);
  }

  function num(value) {
    return isNum(value) ? value : null;
  }

  function esc(value) {
    return String(value).replace(/[&<>"']/g, function (ch) {
      if (ch === '&') return '&amp;';
      if (ch === '<') return '&lt;';
      if (ch === '>') return '&gt;';
      if (ch === '"') return '&quot;';
      return '&#39;';
    });
  }

  function fixed(value, dp) {
    if (!isNum(value)) return DASH;
    var text = value.toFixed(dp);
    if (/^-0(\.0+)?$/.test(text)) text = text.slice(1);
    return text;
  }

  function group(text) {
    var negative = text.charAt(0) === '-';
    var body = negative ? text.slice(1) : text;
    var parts = body.split('.');
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ',');
    return (negative ? '-' : '') + parts.join('.');
  }

  /* Number formatting contract:
   *   1 decimal for most values, 2 for voltages under 20, 2 max elsewhere,
   *   grouped thousands for odometer / energy counters, null -> em dash. */
  function fmt(value) {
    return fixed(value, 1);
  }

  function fmt0(value) {
    return fixed(value, 0);
  }

  function fmt2(value) {
    return fixed(value, 2);
  }

  function fmtV(value) {
    return isNum(value) && Math.abs(value) < 20 ? fixed(value, 2) : fixed(value, 1);
  }

  function fmtG(value, dp) {
    return isNum(value) ? group(fixed(value, dp)) : DASH;
  }

  function fmtOdo(value) {
    return fmtG(value, 1);
  }

  function fmtCoord(value) {
    return isNum(value) ? fixed(value, 4) : DASH;
  }

  function parseTime(value) {
    if (typeof value !== 'string' || !value) return null;
    var ms = Date.parse(value);
    return isNaN(ms) ? null : ms;
  }

  function fmtDateTime(value) {
    var ms = parseTime(value);
    if (ms === null) return DASH;
    try {
      return new Date(ms).toLocaleString(undefined, {
        year: 'numeric',
        month: 'short',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit'
      });
    } catch (e) {
      return DASH;
    }
  }

  function fmtClock(value) {
    var ms = parseTime(value);
    if (ms === null) return DASH;
    try {
      return new Date(ms).toLocaleTimeString(undefined, {
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit'
      });
    } catch (e) {
      return DASH;
    }
  }

  function ageText(seconds) {
    if (!isNum(seconds)) return DASH;
    var sec = Math.max(0, Math.round(seconds));
    if (sec < 60) return sec + 's';
    if (sec < 3600) return Math.floor(sec / 60) + 'm ' + (sec % 60) + 's';
    return Math.floor(sec / 3600) + 'h ' + Math.floor((sec % 3600) / 60) + 'm';
  }

  function fmtDuration(seconds) {
    if (!isNum(seconds)) return DASH;
    var sec = Math.max(0, Math.round(seconds));
    var hours = Math.floor(sec / 3600);
    var mins = Math.floor((sec % 3600) / 60);
    var rest = sec % 60;
    if (hours > 0) return hours + 'h ' + mins + 'm';
    if (mins > 0) return mins + 'm ' + rest + 's';
    return rest + 's';
  }

  function fmtUptime(seconds) {
    if (!isNum(seconds)) return DASH;
    var sec = Math.max(0, Math.floor(seconds));
    var days = Math.floor(sec / 86400);
    var hours = Math.floor((sec % 86400) / 3600);
    var mins = Math.floor((sec % 3600) / 60);
    var rest = sec % 60;
    if (days > 0) return days + 'd ' + hours + 'h ' + mins + 'm';
    if (hours > 0) return hours + 'h ' + mins + 'm ' + rest + 's';
    if (mins > 0) return mins + 'm ' + rest + 's';
    return rest + 's';
  }

  function sourceLabel(source) {
    if (typeof source !== 'string' || !source) return 'unknown';
    var key = source.toLowerCase();
    return SOURCE_LABELS[key] || source;
  }

  function compass(heading) {
    if (!isNum(heading)) return '';
    var dirs = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    var index = Math.round((((heading % 360) + 360) % 360) / 45) % 8;
    return dirs[index];
  }

  function formatForKey(key, value) {
    if (!isNum(value)) return DASH;
    if (key === 'odometer') return fmtOdo(value);
    if (VOLTAGE_RE.test(key)) return fmtV(value);
    if (Number.isInteger(value)) return group(String(value));
    return fmt(value);
  }

  function pick(data, key) {
    return data && typeof data === 'object' && isNum(data[key]) ? data[key] : null;
  }

  function pickFirst(data, keys) {
    for (var i = 0; i < keys.length; i++) {
      var value = pick(data, keys[i]);
      if (value !== null) return value;
    }
    return null;
  }

  function cellValues(data, key) {
    if (!data || !Array.isArray(data[key])) return [];
    return data[key].filter(isNum);
  }

  /* ================================================================== *
   * App state
   * ================================================================== */

  var state = {
    route: 'dashboard',
    server: null,
    data: null,
    dataAge: null,
    snapshotAt: 0,
    connection: 'connecting',
    lastErrorText: null,
    auth: { denied: false, modalOpen: false, mutedUntil: 0 },
    history: { soc: [], power: [], voltage: [] },
    lastHistoryTimestamp: null,
    sessions: [],
    sessionsError: null,
    logs: [],
    logsError: null,
    logsPaused: false,
    autoScroll: true,
    liveFilter: '',
    liveSort: { field: 'key', dir: 1 },
    logFilter: '',
    settings: null,
    settingsError: null,
    fleet: null,
    fleetError: null,
    fleetLoaded: false,
    manual: null,
    manualError: null,
    manualRev: 0
  };

  var inflight = { state: false, sessions: false, logs: false, settings: false, fleet: false, manual: false };
  var timers = { state: null, sessions: null, logs: null, settings: null, tick: null };
  var lastFocusedElement = null;
  var toastTimer = null;

  /* ================================================================== *
   * Auth token
   * ================================================================== */

  function getToken() {
    try {
      return localStorage.getItem(TOKEN_KEY) || '';
    } catch (e) {
      return '';
    }
  }

  function setToken(value) {
    try {
      if (value) localStorage.setItem(TOKEN_KEY, value);
      else localStorage.removeItem(TOKEN_KEY);
    } catch (e) {
      /* Private mode / storage disabled: keep the token in memory only. */
    }
  }

  function showTokenError(message) {
    var box = $('#token-error');
    if (!box) return;
    box.textContent = message || '';
    box.hidden = !message;
  }

  function showTokenModal(message) {
    var modal = $('#token-modal');
    if (!modal) return;
    if (!modal.hidden) {
      if (message) showTokenError(message);
      return;
    }
    state.auth.modalOpen = true;
    lastFocusedElement = document.activeElement;
    modal.hidden = false;
    var input = $('#token-input');
    if (input) {
      input.value = '';
      window.setTimeout(function () {
        try {
          input.focus();
        } catch (e) {
          /* ignore */
        }
      }, 30);
    }
    showTokenError(message || '');
  }

  function closeTokenModal() {
    var modal = $('#token-modal');
    if (modal) modal.hidden = true;
    state.auth.modalOpen = false;
    if (lastFocusedElement && typeof lastFocusedElement.focus === 'function') {
      try {
        lastFocusedElement.focus();
      } catch (e) {
        /* ignore */
      }
    }
    lastFocusedElement = null;
  }

  function trapTab(event, root) {
    var focusables = $$('button, input, a[href], [tabindex]:not([tabindex="-1"])', root).filter(function (node) {
      return !node.disabled && node.offsetParent !== null;
    });
    if (!focusables.length) return;
    var first = focusables[0];
    var last = focusables[focusables.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  }

  /* ================================================================== *
   * API access
   * ================================================================== */

  function api(path) {
    var headers = { Accept: 'application/json' };
    var token = getToken();
    if (token) headers['x-token'] = token;

    return fetch(path, {
      method: 'GET',
      headers: headers,
      cache: 'no-store',
      credentials: 'same-origin'
    }).then(function (response) {
      if (response.status === 401) {
        var authError = new Error('unauthorized');
        authError.status = 401;
        throw authError;
      }
      if (!response.ok) {
        var httpError = new Error('HTTP ' + response.status);
        httpError.status = response.status;
        throw httpError;
      }
      return response.json();
    });
  }

  function errText(error) {
    if (!error) return '';
    if (error.status === 401) return 'unauthorized';
    return error.message || 'request failed';
  }

  function handleApiFailure(error) {
    if (error && error.status === 401) {
      state.auth.denied = true;
      state.connection = 'locked';
      state.lastErrorText = 'unauthorized';
      if (!state.auth.modalOpen && Date.now() >= state.auth.mutedUntil) {
        showTokenModal(
          getToken()
            ? 'The server rejected the stored token. Enter the current token from the app.'
            : 'This server has an access token set. Enter it to load live data.'
        );
      }
      return;
    }
    state.connection = 'offline';
    state.lastErrorText = errText(error);
  }

  /* ================================================================== *
   * History + sparklines
   * ================================================================== */

  function pushHistory(series, value) {
    if (!isNum(value)) return;
    var values = state.history[series];
    values.push(value);
    while (values.length > HISTORY_MAX) values.shift();
  }

  function recordHistory(data) {
    if (!data || typeof data !== 'object') return;
    if (data.timestamp && data.timestamp === state.lastHistoryTimestamp) return;
    state.lastHistoryTimestamp = typeof data.timestamp === 'string' ? data.timestamp : null;
    pushHistory('soc', num(data.stateOfCharge));
    pushHistory('power', num(data.power));
    pushHistory('voltage', pickFirst(data, ['batteryVoltage', 'HV_V']));
  }

  function sparkPath(values) {
    if (!values || !values.length) return '';
    var min = Math.min.apply(null, values);
    var max = Math.max.apply(null, values);
    var span = max - min;
    var count = values.length;
    if (count === 1) {
      var only = 13;
      return 'M0 ' + only.toFixed(2) + ' L100 ' + only.toFixed(2);
    }
    var parts = [];
    for (var i = 0; i < count; i++) {
      var x = (i / (count - 1)) * 100;
      var y = span === 0 ? 13 : 25 - ((values[i] - min) / span) * 22 - 1;
      parts.push((i === 0 ? 'M' : 'L') + x.toFixed(2) + ' ' + y.toFixed(2));
    }
    return parts.join(' ');
  }

  function renderSparkline(id, series, labeler) {
    var svg = document.getElementById('spark-' + id);
    if (!svg) return;
    var path = svg.querySelector('path');
    if (path) path.setAttribute('d', sparkPath(state.history[series]));
    var last = document.getElementById('spark-' + id + '-last');
    if (!last) return;
    var values = state.history[series];
    last.textContent = values.length ? labeler(values[values.length - 1]) : DASH;
  }

  function renderSparklines() {
    renderSparkline('soc', 'soc', function (value) {
      return fmt(value) + '%';
    });
    renderSparkline('power', 'power', function (value) {
      return fmt(value) + ' kW';
    });
    renderSparkline('voltage', 'voltage', function (value) {
      return fmtV(value) + ' V';
    });
  }

  /* ================================================================== *
   * Data freshness
   * ================================================================== */

  function currentAgeSeconds() {
    if (!state.data) return null;
    var base = isNum(state.dataAge) ? state.dataAge : null;
    if (base === null) {
      var dataTime = parseTime(state.data.timestamp);
      var serverTime = parseTime(state.server && state.server.serverTime);
      if (dataTime !== null && serverTime !== null) {
        base = Math.max(0, (serverTime - dataTime) / 1000);
      }
    }
    if (base === null) return null;
    if (state.snapshotAt) base += (Date.now() - state.snapshotAt) / 1000;
    return Math.max(0, Math.round(base));
  }

  function ageInfo() {
    if (!state.data) {
      return {
        text: state.connection === 'online' ? 'waiting for vehicle data' : 'no data',
        cls: 'is-bad'
      };
    }
    var age = currentAgeSeconds();
    if (age === null) return { text: 'timestamps unavailable', cls: 'is-bad' };
    return {
      text: 'updated ' + ageText(age) + ' ago',
      cls: age > 120 ? 'is-bad' : age > 30 ? 'is-warn' : 'is-ok'
    };
  }

  /* ================================================================== *
   * Markup helpers
   * ================================================================== */

  function kv(label, value, unit) {
    var missing = value === null || value === undefined || value === '' || value === DASH;
    return (
      '<div class="kv-row"><dt>' +
      esc(label) +
      '</dt><dd>' +
      (missing ? DASH : value) +
      (!missing && unit ? '<span class="unit">' + esc(unit) + '</span>' : '') +
      '</dd></div>'
    );
  }

  function kvList(inner) {
    return '<dl class="kv">' + inner + '</dl>';
  }

  function card(title, body, icon, note) {
    return (
      '<section class="card">' +
      '<h2 class="card-title">' +
      (icon || '') +
      '<span>' +
      esc(title) +
      '</span>' +
      (note ? '<span class="card-note">' + note + '</span>' : '') +
      '</h2>' +
      body +
      '</section>'
    );
  }

  function cellGrid(values, unit, highIsGood, label) {
    var min = Math.min.apply(null, values);
    var max = Math.max.apply(null, values);
    var span = max - min;
    var dp = unit === 'V' ? 2 : 1;
    var html = '<div class="cellgrid" role="group" aria-label="' + esc(label) + '">';
    for (var i = 0; i < values.length; i++) {
      var value = values[i];
      var t = span > 0 ? (value - min) / span : 0.5;
      if (!highIsGood) t = 1 - t;
      var hue = Math.round(t * 135);
      var classes = 'cell';
      if (value === min) classes += ' is-min';
      if (value === max) classes += ' is-max';
      html +=
        '<span class="' + classes + '" style="--h:' + hue + '" title="' +
        esc(label + ' ' + (i + 1) + ': ' + fixed(value, dp) + ' ' + unit) + '">' +
        fixed(value, dp) +
        '</span>';
    }
    return html + '</div>';
  }

  /* ================================================================== *
   * Render: status strip
   * ================================================================== */

  function renderStatus() {
    var link = $('#status-link');
    var linkText = $('#status-link-text');
    if (!link || !linkText) return;

    var linkClass = 'chip';
    var linkLabel = 'connecting';
    if (state.auth.denied || state.connection === 'locked') {
      linkClass += ' is-warn';
      linkLabel = 'locked';
    } else if (state.connection === 'offline') {
      linkClass += ' is-bad';
      linkLabel = 'offline';
    } else if (state.connection === 'online') {
      linkClass += ' is-ok';
      linkLabel = 'live';
    }
    link.className = linkClass;
    linkText.textContent = linkLabel;

    var server = state.server;
    var source = $('#status-source');
    if (source) source.textContent = 'source ' + sourceLabel(server && server.source);
    var version = $('#status-version');
    if (version) version.textContent = server && server.version ? 'v' + server.version : 'v' + DASH;

    var updated = $('#status-updated');
    if (updated) {
      var info = ageInfo();
      updated.className = 'chip ' + info.cls;
      updated.textContent = info.text;
    }

    var auth = $('#status-auth');
    if (auth) auth.hidden = !(server && server.authRequired);

    var heroUpdated = $('#hero-updated');
    if (heroUpdated) {
      var heroInfo = ageInfo();
      heroUpdated.className = 'hero-updated ' + heroInfo.cls;
      heroUpdated.textContent = heroInfo.text;
    }
  }

  /* ================================================================== *
   * Render: dashboard
   * ================================================================== */

  function cardHv(data) {
    return card(
      'HV battery',
      kvList(
        kv('Pack voltage · HV_V', fmtV(pickFirst(data, ['batteryVoltage', 'HV_V'])), 'V') +
          kv('Pack current · HV_A', fmt(pickFirst(data, ['batteryCurrent', 'HV_A'])), 'A') +
          kv('BMS pack voltage', fmtV(pick(data, 'BMS_HV_V')), 'V') +
          kv('Capacity', fmt(pick(data, 'batteryCapacity')), 'kWh') +
          kv('State of health · SOH', fmt(pickFirst(data, ['stateOfHealth', 'SOH'])), '%') +
          kv('Pack temperature', fmt(pick(data, 'batteryTemperature')), '\u00b0C') +
          kv('Cumulative charge', fmtG(pick(data, 'cumulativeCharge'), 1), 'Ah') +
          kv('Cumulative discharge', fmtG(pick(data, 'cumulativeDischarge'), 1), 'Ah')
      ),
      ICON.battery
    );
  }

  function cardAux(data) {
    var aux = pick(data, 'AUX_V');
    var warn = aux !== null && aux < 12.0;
    return card(
      '12V auxiliary',
      '<div class="big-value' + (warn ? ' is-warn' : '') + '">' + fmtV(aux) + '<span class="unit">V</span></div>' +
        '<p class="hint">AUX_V — the 12 V rail reported by the BMS. Below 12.0 V is worth checking.</p>',
      ICON.plug,
      warn ? 'low' : ''
    );
  }

  function cardCells(data) {
    var cells = cellValues(data, 'cellVoltages');
    var hasGrid = cells.length > 0;
    var min = hasGrid ? Math.min.apply(null, cells) : pick(data, 'HV_C_V_MIN');
    var max = hasGrid ? Math.max.apply(null, cells) : pick(data, 'HV_C_V_MAX');
    var delta = min !== null && max !== null ? max - min : null;
    var avg = pickFirst(data, ['cellVoltageAvg', 'CELL_V_AVG']);
    var updated = data && data.cellVoltagesLastUpdated ? fmtClock(data.cellVoltagesLastUpdated) : DASH;

    var body = kvList(
      kv('Min cell', fmtV(min), 'V') +
        kv('Max cell', fmtV(max), 'V') +
        kv('Delta', delta === null ? DASH : fmt2(delta), 'V') +
        kv('Average cell', fmtV(avg), 'V') +
        kv('Updated', updated)
    );

    if (hasGrid) {
      body += cellGrid(cells, 'V', true, 'Cell');
      body +=
        '<div class="cell-legend"><span>min ' + fmtV(min) + ' V</span><span>' +
        cells.length + ' cells</span><span>max ' + fmtV(max) + ' V</span></div>';
    } else {
      body += '<p class="hint">No per-cell voltage frame yet — showing the BMS pack minimum and maximum.</p>';
    }

    return card('Cells', body, ICON.grid, hasGrid ? cells.length + ' cells' : 'min/max only');
  }

  function cardCellTemps(data) {
    var temps = cellValues(data, 'cellTemperatures');
    var hasGrid = temps.length > 0;
    var min = hasGrid ? Math.min.apply(null, temps) : pick(data, 'HV_T_MIN');
    var max = hasGrid ? Math.max.apply(null, temps) : pick(data, 'HV_T_MAX');
    var delta = min !== null && max !== null ? max - min : null;
    var avg = pickFirst(data, ['cellTempAvg', 'CELL_T_AVG']);
    var updated = data && data.cellTempsLastUpdated ? fmtClock(data.cellTempsLastUpdated) : DASH;

    var body = kvList(
      kv('Min cell temp', fmt(min), '\u00b0C') +
        kv('Max cell temp', fmt(max), '\u00b0C') +
        kv('Delta', delta === null ? DASH : fmt(delta), '\u00b0C') +
        kv('Average cell temp', fmt(avg), '\u00b0C') +
        kv('Updated', updated)
    );

    if (hasGrid) {
      body += cellGrid(temps, '\u00b0C', false, 'Cell');
      body +=
        '<div class="cell-legend"><span>coolest ' + fmt(min) + ' \u00b0C</span><span>' +
        temps.length + ' sensors</span><span>warmest ' + fmt(max) + ' \u00b0C</span></div>';
    } else {
      body += '<p class="hint">No per-sensor temperature frame yet — showing the BMS pack minimum and maximum.</p>';
    }

    return card('Cell temperatures', body, ICON.thermometer, hasGrid ? temps.length + ' sensors' : 'min/max only');
  }

  function cardDrivetrain(data) {
    return card(
      'Drivetrain',
      kvList(
        kv('Front motor', fmt0(pick(data, 'FRONT_MOTOR_RPM')), 'rpm') +
          kv('Rear motor', fmt0(pick(data, 'REAR_MOTOR_RPM')), 'rpm') +
          kv('Front torque request', fmt(pick(data, 'FRONT_MOTOR_TORQUE_REQ')), 'Nm') +
          kv('Rear torque request', fmt(pick(data, 'REAR_MOTOR_TORQUE_REQ')), 'Nm') +
          kv('Motor coolant', fmt(pick(data, 'MOTOR_T')), '\u00b0C') +
          kv('Battery coolant', fmt(pick(data, 'COOLANT_T')), '\u00b0C')
      ),
      ICON.motor
    );
  }

  function cardPedals(data) {
    return card(
      'Pedals & brake',
      kvList(
        kv('Accelerator pedal', fmt(pick(data, 'ACCEL_PEDAL')), '%') +
          kv('Brake pressure', fmt(pick(data, 'BRAKE_PRESSURE')), 'bar')
      ),
      ICON.pedal
    );
  }

  function cardDc(data) {
    return card(
      'DC charge',
      kvList(
        kv('DC charge voltage', fmtV(pick(data, 'DC_CHG_V')), 'V') +
          kv('DC charge current', fmt(pick(data, 'DC_CHG_A')), 'A') +
          kv('Fast charge temp 1', fmt(pick(data, 'FAST_CHG_T1')), '\u00b0C') +
          kv('Fast charge temp 2', fmt(pick(data, 'FAST_CHG_T2')), '\u00b0C')
      ),
      ICON.plug
    );
  }

  function cardChargeStatus(data) {
    return card(
      'Charge status',
      kvList(
        kv('HVIL · CHARGING_HVIL', fmt0(pick(data, 'CHARGING_HVIL'))) +
          kv('BMS charge status', fmt0(pick(data, 'BMS_CHG_STATUS'))) +
          kv('VCU SoC', fmt(pick(data, 'VCU_SOC')), '%') +
          kv('Charge limit', fmt0(pick(data, 'CHG_LIMIT')), '%') +
          kv('Slow charge temp 1', fmt(pick(data, 'SLOW_CHG_T1')), '\u00b0C') +
          kv('Slow charge temp 2', fmt(pick(data, 'SLOW_CHG_T2')), '\u00b0C') +
          kv('Slow charge temp 3', fmt(pick(data, 'SLOW_CHG_T3')), '\u00b0C')
      ),
      ICON.activity
    );
  }

  function cardGps(data) {
    var lat = pick(data, 'latitude');
    var lon = pick(data, 'longitude');
    var heading = pick(data, 'heading');
    var headingText = heading === null ? DASH : fmt0(heading) + '\u00b0' + (compass(heading) ? ' ' + compass(heading) : '');
    var link = '';

    if (lat !== null && lon !== null) {
      var url =
        'https://www.openstreetmap.org/?mlat=' + encodeURIComponent(lat) +
        '&mlon=' + encodeURIComponent(lon) +
        '#map=17/' + encodeURIComponent(lat) + '/' + encodeURIComponent(lon);
      link =
        '<p class="hint"><a class="link" href="' + esc(url) + '" target="_blank" rel="noopener noreferrer">Open in OpenStreetMap</a></p>';
    }

    return card(
      'GPS',
      kvList(
        kv('Latitude', fmtCoord(lat), '\u00b0') +
          kv('Longitude', fmtCoord(lon), '\u00b0') +
          kv('Altitude', fmt(pick(data, 'altitude')), 'm') +
          kv('Heading', headingText) +
          kv('GPS speed', fmt(pick(data, 'gpsSpeed')), 'km/h')
      ) + link,
      ICON.gps
    );
  }

  function cardVehicle(data) {
    return card(
      'Vehicle',
      kvList(
        kv('Speed', fmt(pick(data, 'speed')), 'km/h') +
          kv('Odometer', fmtOdo(pick(data, 'odometer')), 'km') +
          kv('Estimated range', fmt(pick(data, 'range')), 'km') +
          kv('CLTC range', fmt(pick(data, 'CLTC_RANGE')), 'km')
      ),
      ICON.car
    );
  }

  function chargePillText(data) {
    var status = data && typeof data.chargingStatus === 'string' ? data.chargingStatus : '';
    var description = data && typeof data.chargingStatusDescription === 'string' ? data.chargingStatusDescription : '';
    var word = status === 'A' ? 'Standby' : status === 'C' ? 'Charging' : status ? 'Status ' + status : 'Unknown';
    return description ? word + ' · ' + description : word;
  }

  function renderHero(data) {
    var soc = num(data.stateOfCharge);
    var range = num(data.range);
    var power = num(data.power);

    var fill = $('#soc-ring-fill');
    if (fill) {
      var radius = 64;
      var circumference = 2 * Math.PI * radius;
      var clamped = soc === null ? 0 : Math.min(100, Math.max(0, soc));
      fill.setAttribute('stroke-dasharray', circumference.toFixed(2));
      fill.setAttribute('stroke-dashoffset', (circumference * (1 - clamped / 100)).toFixed(2));
      fill.setAttribute(
        'class',
        'ring-fill' + (soc !== null && soc < 10 ? ' is-bad' : soc !== null && soc < 20 ? ' is-warn' : '')
      );
    }

    var socValue = $('#soc-value');
    if (socValue) socValue.textContent = soc === null ? DASH : fmt(soc) + '%';

    var socRange = $('#soc-range');
    if (socRange) socRange.textContent = 'Range ' + (range === null ? DASH : fmt(range) + ' km');

    var pill = $('#charge-pill');
    if (pill) {
      var charging = data.isCharging === true || data.chargingStatus === 'C';
      pill.textContent = chargePillText(data);
      pill.className = 'pill' + (charging ? ' is-charging' : '');
    }

    var powerValue = $('#power-value');
    if (powerValue) {
      powerValue.textContent = fmt(power);
      powerValue.className =
        'hero-power-value' +
        (power === null ? '' : power < -0.05 ? ' is-charging' : power > 0.05 ? ' is-discharging' : '');
    }

    var powerNote = $('#power-note');
    if (powerNote) {
      powerNote.textContent =
        power === null ? '' : power < -0.05 ? 'charging into battery' : power > 0.05 ? 'discharging' : 'idle';
    }

    var speed = $('#hero-speed');
    if (speed) {
      var kmh = num(data.speed);
      speed.textContent = kmh === null ? DASH : fmt(kmh) + ' km/h';
    }

    var odo = $('#hero-odo');
    if (odo) {
      var km = num(data.odometer);
      odo.textContent = km === null ? DASH : fmtOdo(km) + ' km';
    }

    var time = $('#hero-time');
    if (time) time.textContent = data.localTime ? String(data.localTime) : DASH;
  }

  function updateWaitingHint() {
    var hint = $('#waiting-hint');
    if (!hint) return;
    if (state.auth.denied) {
      hint.textContent = 'This server requires an access token. Unlock it to load vehicle data.';
    } else if (state.connection === 'offline') {
      hint.textContent = 'Cannot reach the embedded server right now — check that the car is on the same network.';
    } else {
      hint.textContent =
        'The web server is up but the app has not received a frame from the car yet. Values appear as soon as the first poll completes.';
    }
  }

  function renderDashboard() {
    var data = state.data;
    var waiting = $('#waiting');
    var content = $('#dash-content');

    if (!data) {
      if (waiting) waiting.hidden = false;
      if (content) content.hidden = true;
      updateWaitingHint();
      renderSparklines();
      return;
    }

    if (waiting) waiting.hidden = true;
    if (content) content.hidden = false;

    renderHero(data);
    renderSparklines();

    var grid = $('#dash-cards');
    if (grid) {
      grid.innerHTML = [
        cardHv(data),
        cardAux(data),
        cardCells(data),
        cardCellTemps(data),
        cardDrivetrain(data),
        cardPedals(data),
        cardDc(data),
        cardChargeStatus(data),
        cardGps(data),
        cardVehicle(data)
      ].join('');
    }
  }

  /* ================================================================== *
   * Render: live table
   * ================================================================== */

  function liveRows() {
    var data = state.data;
    if (!data || typeof data !== 'object') return [];
    var raw = data.rawBytes && typeof data.rawBytes === 'object' && !Array.isArray(data.rawBytes) ? data.rawBytes : {};
    var rows = [];
    Object.keys(data).forEach(function (key) {
      if (key === 'rawBytes' || key === 'cellVoltages' || key === 'cellTemperatures') return;
      if (!isNum(data[key])) return;
      var rawValue = raw[key];
      rows.push({
        key: key,
        value: data[key],
        raw: typeof rawValue === 'string' ? rawValue : ''
      });
    });
    return rows;
  }

  function sortLiveRows(rows) {
    var field = state.liveSort.field;
    var dir = state.liveSort.dir;
    rows.sort(function (a, b) {
      if (field === 'key') {
        var ak = a.key.toLowerCase();
        var bk = b.key.toLowerCase();
        if (ak === bk) return 0;
        return (ak < bk ? -1 : 1) * dir;
      }
      if (a.value === b.value) return 0;
      return (a.value < b.value ? -1 : 1) * dir;
    });
  }

  function updateSortHeaders() {
    $$('#live-table th').forEach(function (th) {
      var field = th.getAttribute('data-field');
      if (!field) return;
      if (field === state.liveSort.field) {
        th.setAttribute('aria-sort', state.liveSort.dir === 1 ? 'ascending' : 'descending');
      } else {
        th.setAttribute('aria-sort', 'none');
      }
    });
  }

  function renderLive() {
    var body = $('#live-body');
    if (!body) return;
    var rows = liveRows();
    var query = state.liveFilter.trim().toLowerCase();
    var filtered = query
      ? rows.filter(function (row) {
          return row.key.toLowerCase().indexOf(query) >= 0 || row.raw.toLowerCase().indexOf(query) >= 0;
        })
      : rows.slice();

    sortLiveRows(filtered);

    body.innerHTML = filtered
      .map(function (row) {
        return (
          '<tr><td class="key">' + esc(row.key) + '</td>' +
          '<td class="val">' + formatForKey(row.key, row.value) + '</td>' +
          '<td class="hex">' + (row.raw ? esc(row.raw) : '<span class="muted">' + DASH + '</span>') + '</td></tr>'
        );
      })
      .join('');

    var count = $('#live-count');
    if (count) {
      count.textContent = query ? filtered.length + ' of ' + rows.length + ' keys' : rows.length + ' keys';
    }

    var empty = $('#live-empty');
    if (empty) {
      empty.hidden = filtered.length > 0;
      if (!filtered.length) {
        empty.textContent = !state.data
          ? 'Waiting for vehicle data…'
          : query
            ? 'No keys match “' + state.liveFilter.trim() + '”.'
            : 'This frame has no numeric keys.';
      }
    }

    var table = $('#live-table');
    if (table) table.hidden = rows.length === 0;

    updateSortHeaders();
  }

  /* ================================================================== *
   * Render: charging sessions
   * ================================================================== */

  function summaryItem(value, label) {
    return (
      '<div class="summary-item"><span class="summary-value">' + value +
      '</span><span class="summary-label">' + esc(label) + '</span></div>'
    );
  }

  function sessionCard(session) {
    var active = session.isActive === true;
    var type = typeof session.chargingType === 'string' ? session.chargingType.toLowerCase() : '';
    var typeLabel = type === 'ac' ? 'AC' : type === 'dc' ? 'DC' : type ? type.toUpperCase() : 'Unknown';
    var typeClass = type === 'dc' ? ' is-dc' : type === 'ac' ? ' is-ac' : '';
    var startSoc = num(session.startSoc);
    var endSoc = num(session.endSoc);
    var socText =
      startSoc === null && endSoc === null
        ? DASH
        : (startSoc === null ? DASH : fmt(startSoc) + '%') +
          ' → ' +
          (endSoc === null ? DASH : fmt(endSoc) + '%');
    var cost = num(session.chargingCost);
    var energy = num(session.energyAddedKwh);
    /* The server reports energyAddedKwh as 0 for a session that is still in
       progress (the total is only settled when it ends), so do not show a
       misleading "0.0 kWh" next to a charging badge. */
    var energyPending = active && (energy === null || energy === 0);
    var location =
      typeof session.locationName === 'string' && session.locationName.trim() ? session.locationName.trim() : '';
    var title = location || 'Charging session';
    var duration = active ? 'In progress' : fmtDuration(session.durationSeconds);

    return (
      '<section class="card session-card' + (active ? ' is-active' : '') + '">' +
      '<h2 class="card-title"><span>' + esc(title) + '</span>' +
      '<span class="card-note">' + esc(fmtDateTime(session.startTime)) + '</span></h2>' +
      '<div class="card-badges">' +
      (active ? '<span class="badge is-active">charging</span>' : '') +
      '<span class="badge' + typeClass + '">' + esc(typeLabel) + '</span>' +
      (!active && !session.endTime ? '<span class="badge">open</span>' : '') +
      '</div>' +
      kvList(
        kv('Duration', duration) +
          kv('Energy added', energyPending ? 'In progress' : fmt(energy), energyPending ? '' : 'kWh') +
          kv('SOC', socText) +
          kv('Max power', fmt(num(session.maxPowerKw)), 'kW') +
          kv('Cost', cost === null ? DASH : fmt2(cost)) +
          kv('Location', location ? esc(location) : DASH) +
          kv('Consumption', fmt(num(session.consumptionKwhPer100km)), 'kWh/100 km') +
          kv('Distance since last charge', fmt(num(session.distanceSinceLastCharge)), 'km')
      ) +
      '</section>'
    );
  }

  function renderSessions() {
    var list = $('#sessions-list');
    var summary = $('#sessions-summary');
    var empty = $('#sessions-empty');
    var sessions = Array.isArray(state.sessions) ? state.sessions.filter(Boolean) : [];

    var active = sessions.filter(function (session) {
      return session.isActive === true;
    });
    var past = sessions.filter(function (session) {
      return session.isActive !== true;
    });
    past.sort(function (a, b) {
      var at = parseTime(a.startTime);
      var bt = parseTime(b.startTime);
      return (bt === null ? 0 : bt) - (at === null ? 0 : at);
    });
    var ordered = active.concat(past);

    if (list) list.innerHTML = ordered.map(sessionCard).join('');

    if (summary) {
      var kwhValues = ordered
        .map(function (session) {
          return num(session.energyAddedKwh);
        })
        .filter(function (value) {
          return value !== null;
        });
      var total = kwhValues.reduce(function (acc, value) {
        return acc + value;
      }, 0);
      var average = kwhValues.length ? total / kwhValues.length : null;
      summary.innerHTML =
        summaryItem(String(ordered.length), ordered.length === 1 ? 'session' : 'sessions') +
        summaryItem(kwhValues.length ? fmtG(total, 1) + ' kWh' : DASH, 'total added') +
        summaryItem(average === null ? DASH : fmtG(average, 1) + ' kWh', 'average / session');
    }

    if (empty) {
      empty.hidden = ordered.length > 0;
      empty.textContent = state.sessionsError
        ? 'Charging sessions are unavailable (' + errText(state.sessionsError) + ').'
        : 'No charging sessions recorded yet.';
    }
  }

  /* ================================================================== *
   * Render: logs
   * ================================================================== */

  function visibleLogs() {
    var lines = Array.isArray(state.logs) ? state.logs : [];
    var query = state.logFilter.trim().toLowerCase();
    if (!query) return lines;
    return lines.filter(function (line) {
      return String(line).toLowerCase().indexOf(query) >= 0;
    });
  }

  function renderLogs() {
    var view = $('#log-view');
    if (!view) return;
    var visible = visibleLogs();
    var all = Array.isArray(state.logs) ? state.logs : [];

    if (view.textContent !== visible.join('\n')) {
      var keepScroll = state.autoScroll ? null : view.scrollTop;
      view.textContent = visible.join('\n');
      if (state.autoScroll) view.scrollTop = view.scrollHeight;
      else if (keepScroll !== null) view.scrollTop = keepScroll;
    }

    var count = $('#log-count');
    if (count) {
      var query = state.logFilter.trim();
      count.textContent = query
        ? visible.length + ' of ' + all.length + ' lines'
        : all.length + (all.length === 1 ? ' line' : ' lines');
    }

    var pause = $('#log-pause');
    if (pause) {
      pause.setAttribute('aria-pressed', state.logsPaused ? 'true' : 'false');
      pause.textContent = state.logsPaused ? 'Resume' : 'Pause';
    }
  }

  function copyLogs() {
    var lines = visibleLogs();
    if (!lines.length) {
      toast('Nothing to copy');
      return;
    }
    var text = lines.join('\n');

    function done() {
      toast('Copied ' + lines.length + (lines.length === 1 ? ' line' : ' lines'));
    }

    function fallback() {
      var area = document.createElement('textarea');
      area.value = text;
      area.setAttribute('readonly', '');
      area.style.position = 'fixed';
      area.style.top = '-1000px';
      area.style.left = '-1000px';
      document.body.appendChild(area);
      area.select();
      var ok = false;
      try {
        ok = document.execCommand('copy');
      } catch (e) {
        ok = false;
      }
      document.body.removeChild(area);
      toast(ok ? 'Copied ' + lines.length + (lines.length === 1 ? ' line' : ' lines') : 'Copy failed');
    }

    if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
      navigator.clipboard.writeText(text).then(done, fallback);
    } else {
      fallback();
    }
  }

  /* ================================================================== *
   * Render: about
   * ================================================================== */

  function renderAbout() {
    var server = state.server;
    var data = state.data;
    var age = currentAgeSeconds();
    var dl = $('#about-server');

    if (dl) {
      dl.innerHTML =
        kv('Status', server ? (server.running ? 'Running' : 'Stopped') : DASH) +
        kv('Version', server && server.version ? esc(server.version) : DASH) +
        kv('Port', server && isNum(server.port) ? fmt0(server.port) : DASH) +
        kv('Uptime', server ? fmtUptime(server.uptimeSeconds) : DASH) +
        kv('Started', server ? esc(fmtDateTime(server.startedAt)) : DASH) +
        kv('Data source', esc(sourceLabel(server && server.source))) +
        kv('Data age', age === null ? DASH : ageText(age)) +
        kv('Auth required', server ? (server.authRequired ? 'Yes' : 'No') : DASH) +
        kv('Server time', server ? esc(fmtDateTime(server.serverTime)) : DASH) +
        kv('Vehicle time', data && data.localTime ? esc(data.localTime) : DASH);
    }

    var tokenState = $('#about-token-state');
    if (tokenState) {
      tokenState.textContent = getToken()
        ? 'A token is stored in this browser. If it is rejected, change it here.'
        : 'No token stored. If the server has a token set, unlock it to load data.';
    }
  }

  /* ================================================================== *
   * Render: settings (read-only), fleet, manual
   * ================================================================== */

  function modelLabel(code) {
    if (typeof code !== 'string' || !code) return 'Unknown model';
    if (MODEL_LABELS[code]) return MODEL_LABELS[code];
    if (LEGACY_MODEL_LABELS[code]) return LEGACY_MODEL_LABELS[code];
    var parts = code.split('_');
    var model = parts[0];
    var rest = parts.slice(1);
    var year = null;
    if (rest.length && /^\d{2}$/.test(rest[0])) {
      year = '20' + rest[0];
      rest = rest.slice(1);
    }
    var tail = rest.join('/');
    return (model + (year ? ' ' + year : '') + (tail ? ' ' + tail : '')).trim();
  }

  function onOff(value) {
    if (value === true) return '<span class="state is-on">On</span>';
    if (value === false) return '<span class="state is-off">Off</span>';
    return DASH;
  }

  function configuredChip(value) {
    if (value === true) return '<span class="badge is-active">Configured</span>';
    if (value === false) return '<span class="badge">Not configured</span>';
    return DASH;
  }

  function requiredChip(value) {
    if (value === true) return '<span class="badge is-warn">Required</span>';
    if (value === false) return '<span class="badge">Not required</span>';
    return DASH;
  }

  function labelledChip(value, onLabel, offLabel) {
    if (value === true) return '<span class="badge is-active">' + esc(onLabel) + '</span>';
    if (value === false) return '<span class="badge">' + esc(offLabel) + '</span>';
    return DASH;
  }

  /* Mirrors the Connections screen: 0 means auto-reconnect is disabled. */
  function reconnectText(seconds) {
    var value = num(seconds);
    if (value === null) return DASH;
    if (value === 0) return 'Disabled';
    return 'every ' + fmt0(value) + 's';
  }

  function settingsVehicleCard(vehicle) {
    var v = vehicle && typeof vehicle === 'object' ? vehicle : {};
    var code = typeof v.model === 'string' && v.model ? v.model : null;
    var label = code ? modelLabel(code) : null;
    var modelValue = label
      ? esc(label) + (label !== code ? ' <span class="muted">(' + esc(code) + ')</span>' : '')
      : DASH;
    var rows = kv('Model', modelValue);
    var custom = num(v.customCapacityKwh);
    if (code === 'CUSTOM' && custom !== null) {
      rows += kv('Custom capacity', fmt(custom), 'kWh');
    }
    return card('Vehicle', kvList(rows), ICON.car);
  }

  function settingsBehaviourCard(behavior) {
    var b = behavior && typeof behavior === 'object' ? behavior : {};
    return card(
      'App behaviour',
      kvList(
        kv('Update frequency', fmt0(b.updateFrequencySeconds), 's') +
          kv('Start minimised', onOff(b.startMinimised)) +
          kv('Stay in background', onOff(b.stayInBackground)) +
          kv('Keep-alive service', onOff(b.keepAliveEnabled)) +
          kv('Background service', onOff(b.backgroundServiceEnabled)) +
          kv('Automatic update check', onOff(b.autoUpdateCheck)) +
          kv('Location access', onOff(b.locationEnabled))
      ),
      ICON.settings
    );
  }

  function settingsAlertsCard(alerts) {
    var a = alerts && typeof alerts === 'object' ? alerts : {};
    return card(
      'Alerts & protection',
      kvList(
        kv('Low battery alert', fmt(a.lowBatteryPercent), '%') +
          kv('Critical battery alert', fmt(a.criticalBatteryPercent), '%') +
          kv('High temperature alert', fmt(a.highTemperatureCelsius), '\u00b0C') +
          kv('12V aux protection', onOff(a.auxBatteryProtection)) +
          kv('12V aux threshold', fmtV(a.auxBatteryThresholdVolts), 'V')
      ),
      ICON.shield
    );
  }

  function settingsMqttCard(mqtt) {
    var m = mqtt && typeof mqtt === 'object' ? mqtt : {};
    return card(
      'MQTT / Home Assistant',
      kvList(
        kv('Enable MQTT Publishing', onOff(m.enabled)) +
          kv('Broker Address', typeof m.broker === 'string' && m.broker ? esc(m.broker) : DASH) +
          kv('Port', fmt0(m.port)) +
          kv('Vehicle ID', typeof m.vehicleId === 'string' && m.vehicleId ? esc(m.vehicleId) : DASH) +
          kv('Username', typeof m.username === 'string' && m.username ? esc(m.username) : DASH) +
          kv('Password', configuredChip(m.passwordSet)) +
          kv('Use TLS/SSL', onOff(m.tls)) +
          kv('Home Assistant Discovery', onOff(m.homeAssistantDiscovery)) +
          kv('Auto-Reconnect Interval', reconnectText(m.reconnectIntervalSeconds))
      ),
      ICON.wifi
    );
  }

  function settingsTailscaleCard(tailscale) {
    var t = tailscale && typeof tailscale === 'object' ? tailscale : {};
    return card(
      'Tailscale',
      kvList(
        kv('Installed', labelledChip(t.installed, 'Installed', 'Not found')) +
          kv('VPN active', onOff(t.vpnActive)) +
          kv('Auto-Connect on Startup', onOff(t.autoConnect)) +
          kv('Auto-Reconnect', onOff(t.autoReconnect))
      ),
      ICON.vpn
    );
  }

  function settingsObdProxyCard(proxy) {
    var p = proxy && typeof proxy === 'object' ? proxy : {};
    return card(
      'OBD proxy',
      kvList(
        kv('WiFi proxy', onOff(p.enabled)) +
          kv('Port', fmt0(p.port)) +
          kv('Client', labelledChip(p.clientConnected, 'Connected', 'None'))
      ),
      ICON.plug
    );
  }

  function settingsBm300Card(bm300) {
    var b = bm300 && typeof bm300 === 'object' ? bm300 : {};
    return card(
      'BM300 Pro',
      kvList(
        kv('Enabled', onOff(b.enabled)) +
          kv('Battery monitor', labelledChip(b.connected, 'Connected', 'Not connected'))
      ),
      ICON.bluetooth
    );
  }

  function settingsAbrpCard(abrp) {
    var a = abrp && typeof abrp === 'object' ? abrp : {};
    return card(
      'ABRP',
      kvList(
        kv('Telemetry', onOff(a.enabled)) +
          kv('Token', configuredChip(a.tokenConfigured))
      ),
      ICON.route
    );
  }

  function settingsRemoteCard(remote) {
    var r = remote && typeof remote === 'object' ? remote : {};
    return card(
      'Remote access',
      kvList(
        kv('Web server', onOff(r.enabled)) +
          kv('Running', onOff(r.running)) +
          kv('Port', fmt0(r.port)) +
          kv('Token required', requiredChip(r.tokenRequired))
      ),
      ICON.globe
    );
  }

  function distributionBars(distribution) {
    if (!distribution || typeof distribution !== 'object' || Array.isArray(distribution)) return '';
    var entries = [];
    Object.keys(distribution).forEach(function (key) {
      if (isNum(distribution[key])) entries.push([key, distribution[key]]);
    });
    if (!entries.length) return '';
    entries.sort(function (a, b) {
      return b[1] - a[1];
    });
    var max = entries[0][1] || 1;
    return (
      '<div class="dist">' +
      entries
        .map(function (entry) {
          var width = Math.max(2, Math.round((entry[1] / max) * 100));
          return (
            '<div class="dist-row"><span class="dist-label">' + esc(entry[0]) + '</span>' +
            '<span class="dist-bar"><span style="width:' + width + '%"></span></span>' +
            '<span class="dist-value">' + fmtG(entry[1], 0) + '</span></div>'
          );
        })
        .join('') +
      '</div>'
    );
  }

  function countryList(distribution) {
    if (!distribution || typeof distribution !== 'object' || Array.isArray(distribution)) return '';
    var entries = [];
    Object.keys(distribution).forEach(function (key) {
      if (isNum(distribution[key])) entries.push([key, distribution[key]]);
    });
    if (!entries.length) return '';
    entries.sort(function (a, b) {
      return b[1] - a[1];
    });
    return (
      '<ul class="country-list">' +
      entries
        .map(function (entry) {
          return '<li><span>' + esc(entry[0]) + '</span><b>' + fmtG(entry[1], 0) + '</b></li>';
        })
        .join('') +
      '</ul>'
    );
  }

  function settingsFleetCard() {
    var fleet = state.fleet;
    if (!fleet || typeof fleet !== 'object') {
      var message = state.fleetError
        ? 'Fleet statistics unavailable (' + esc(errText(state.fleetError)) + ').'
        : 'Loading fleet statistics…';
      return card('Fleet statistics', '<p class="hint">' + message + '</p>', ICON.cloud);
    }
    if (fleet.enabled !== true) {
      return card(
        'Fleet statistics',
        '<p class="hint">Fleet statistics off (opt-in in the app).</p>',
        ICON.cloud,
        'off'
      );
    }
    var stats = fleet.stats && typeof fleet.stats === 'object' ? fleet.stats : null;
    if (!stats) {
      return card(
        'Fleet statistics',
        '<p class="hint">Waiting for fleet data…</p>',
        ICON.cloud,
        'opted in'
      );
    }

    var body = kvList(
      kv('Contributors', fmtG(num(stats.totalContributors), 0)) +
        kv('Contributions', fmtG(num(stats.totalContributions), 0)) +
        kv('Average SOH', fmt(num(stats.avgSoh)), '%') +
        kv('Average AC power', fmt(num(stats.avgChargingPowerAc)), 'kW') +
        kv('Average DC power', fmt(num(stats.avgChargingPowerDc)), 'kW') +
        (parseTime(stats.lastUpdated) !== null ? kv('Updated', esc(fmtDateTime(stats.lastUpdated))) : '')
    );

    var sohBars = distributionBars(stats.sohDistribution);
    if (sohBars) body += '<p class="hint">SOH distribution</p>' + sohBars;
    var typeBars = distributionBars(stats.chargingTypeDistribution);
    if (typeBars) body += '<p class="hint">Charging type distribution</p>' + typeBars;
    var countries = countryList(stats.countryDistribution);
    if (countries) body += '<p class="hint">Contributors by country</p>' + countries;

    return card('Fleet statistics', body, ICON.cloud, 'anonymous');
  }

  function settingsManualCard() {
    return card(
      'Manual',
      '<p class="hint">The full user manual is bundled with the app and rendered read-only from <code>/api/manual</code>.</p>' +
        '<p class="hint"><a class="btn" href="#/manual">Open the manual</a></p>',
      ICON.book
    );
  }

  function updateSettingsStoreNotice(settings) {
    var notice = $('#settings-store-notice');
    if (!notice) return;
    notice.hidden = !(settings && settings.settingsAvailable === false);
  }

  function renderSettings() {
    var grid = $('#settings-cards');
    if (!grid) return;
    var settings = state.settings;

    /* The inline "store unavailable" banner is outside the card grid, so keep
       it in sync before the change-detection guard below. */
    updateSettingsStoreNotice(settings);

    /* Re-render only when the payload actually changed, so the 2 s state poll
       does not rebuild these cards while the user is reading them. */
    var signature = JSON.stringify([
      settings,
      state.fleet,
      state.settingsError ? errText(state.settingsError) : '',
      state.fleetError ? errText(state.fleetError) : ''
    ]);
    if (grid.getAttribute('data-sig') === signature) return;
    grid.setAttribute('data-sig', signature);

    var cards = [];

    if (settings && typeof settings === 'object') {
      cards.push(settingsVehicleCard(settings.vehicle));
      cards.push(settingsBehaviourCard(settings.behavior));
      cards.push(settingsAlertsCard(settings.alerts));
      cards.push(settingsMqttCard(settings.mqtt));
      cards.push(settingsTailscaleCard(settings.tailscale));
      cards.push(settingsObdProxyCard(settings.obdProxy));
      cards.push(settingsBm300Card(settings.bm300));
      cards.push(settingsAbrpCard(settings.abrp));
      cards.push(settingsRemoteCard(settings.remoteAccess));
    } else {
      var message = state.settingsError
        ? 'Settings unavailable (' + esc(errText(state.settingsError)) + ').'
        : 'Waiting for settings…';
      cards.push(card('Settings', '<p class="hint">' + message + '</p>', ICON.settings));
    }

    cards.push(settingsFleetCard());
    cards.push(settingsManualCard());
    grid.innerHTML = cards.join('');

    var version = $('#settings-app-version');
    if (version) {
      var app = settings && settings.app && typeof settings.app === 'object' ? settings.app : null;
      version.textContent =
        app && typeof app.version === 'string' && app.version ? 'App v' + app.version : 'App v' + DASH;
    }
  }

  /* Minimal, safe markdown renderer for /api/manual. Everything is escaped
     before any markup is added; links are restricted to http(s)/mailto and
     opened with noopener. Internal (#anchor) links are rendered as plain text
     so they cannot hijack the hash router. */
  function renderMarkdown(markdown) {
    if (typeof markdown !== 'string' || !markdown.trim()) {
      return '<p class="hint">The manual is empty.</p>';
    }

    var lines = markdown.replace(/\r\n?/g, '\n').split('\n');
    var out = [];
    var paragraph = [];
    var listType = null;
    var codeLines = null;

    function inline(text) {
      var safe = esc(text);
      safe = safe.replace(
        /\[([^\]]+)\]\((https?:\/\/[^\s)]+|mailto:[^\s)]+)\)/g,
        function (match, label, url) {
          return '<a href="' + url + '" target="_blank" rel="noopener noreferrer">' + label + '</a>';
        }
      );
      safe = safe.replace(/\[([^\]]+)\]\(#[^)]+\)/g, '$1');
      safe = safe.replace(/`([^`]+)`/g, '<code>$1</code>');
      safe = safe.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
      safe = safe.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
      return safe;
    }

    function closeParagraph() {
      if (!paragraph.length) return;
      out.push('<p>' + inline(paragraph.join('\n')).replace(/\n/g, '<br>') + '</p>');
      paragraph = [];
    }

    function closeList() {
      if (!listType) return;
      out.push('</' + listType + '>');
      listType = null;
    }

    function isTableRow(text) {
      return /^\s*\|.*\|\s*$/.test(text);
    }

    function tableCells(row) {
      var trimmed = row.trim();
      if (trimmed.charAt(0) === '|') trimmed = trimmed.slice(1);
      if (trimmed.charAt(trimmed.length - 1) === '|') trimmed = trimmed.slice(0, -1);
      return trimmed.split('|').map(function (cell) {
        return cell.trim();
      });
    }

    function isSeparatorRow(cells) {
      if (!cells.length) return false;
      return cells.every(function (cell) {
        return /^:?-{2,}:?$/.test(cell);
      });
    }

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];

      if (codeLines !== null) {
        if (/^```/.test(line)) {
          out.push('<pre><code>' + esc(codeLines.join('\n')) + '</code></pre>');
          codeLines = null;
        } else {
          codeLines.push(line);
        }
        continue;
      }

      if (/^```/.test(line)) {
        closeParagraph();
        closeList();
        codeLines = [];
        continue;
      }

      if (!line.trim()) {
        closeParagraph();
        closeList();
        continue;
      }

      var heading = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
      if (heading) {
        closeParagraph();
        closeList();
        var level = heading[1].length === 1 ? 2 : Math.min(5, heading[1].length + 1);
        out.push('<h' + level + '>' + inline(heading[2]) + '</h' + level + '>');
        continue;
      }

      if (/^(\*\s*){3,}$/.test(line) || /^(-\s*){3,}$/.test(line) || /^(_\s*){3,}$/.test(line)) {
        closeParagraph();
        closeList();
        out.push('<hr>');
        continue;
      }

      var quote = /^>\s?(.*)$/.exec(line);
      if (quote) {
        closeParagraph();
        closeList();
        out.push('<blockquote>' + inline(quote[1]) + '</blockquote>');
        continue;
      }

      if (isTableRow(line)) {
        closeParagraph();
        closeList();
        var tableRows = [];
        var next = i;
        while (next < lines.length && isTableRow(lines[next])) {
          tableRows.push(lines[next]);
          next += 1;
        }
        var tableHtml = '<div class="manual-table-wrap"><table class="manual-table">';
        var bodyRowIndex = 0;
        for (var r = 0; r < tableRows.length; r++) {
          var cells = tableCells(tableRows[r]);
          if (isSeparatorRow(cells)) continue;
          var tag = bodyRowIndex === 0 ? 'th' : 'td';
          tableHtml +=
            '<tr>' +
            cells
              .map(function (cell, cellIndex) {
                var cellTag = tag;
                return '<' + cellTag + '>' + inline(cell) + '</' + cellTag + '>';
              })
              .join('') +
            '</tr>';
          bodyRowIndex += 1;
        }
        tableHtml += '</table></div>';
        out.push(tableHtml);
        i = next - 1;
        continue;
      }

      var bullet = /^\s*[-*+]\s+(.*)$/.exec(line);
      if (bullet) {
        closeParagraph();
        if (listType !== 'ul') {
          closeList();
          out.push('<ul>');
          listType = 'ul';
        }
        out.push('<li>' + inline(bullet[1]) + '</li>');
        continue;
      }

      var numbered = /^\s*(\d+)[.)]\s+(.*)$/.exec(line);
      if (numbered) {
        closeParagraph();
        if (listType !== 'ol') {
          closeList();
          out.push('<ol>');
          listType = 'ol';
        }
        out.push('<li value="' + numbered[1] + '">' + inline(numbered[2]) + '</li>');
        continue;
      }

      closeList();
      paragraph.push(line);
    }

    if (codeLines !== null) out.push('<pre><code>' + esc(codeLines.join('\n')) + '</code></pre>');
    closeParagraph();
    closeList();
    return out.join('\n');
  }

  function renderManual() {
    var body = $('#manual-body');
    if (!body) return;
    var revision = String(state.manualRev);
    if (body.getAttribute('data-rev') === revision) return;

    var html;
    if (state.manual === null) {
      html = state.manualError
        ? '<p class="hint">Manual unavailable (' + esc(errText(state.manualError)) + ').</p>'
        : '<p class="hint">Loading manual…</p>';
    } else {
      html = renderMarkdown(state.manual);
    }
    body.innerHTML = html;
    body.setAttribute('data-rev', revision);
  }

  /* ================================================================== *
   * Router
   * ================================================================== */

  function currentRoute() {
    var raw = (location.hash || '').replace(/^#\/?/, '').split(/[/?]/)[0].toLowerCase();
    return PAGES.indexOf(raw) >= 0 ? raw : 'dashboard';
  }

  function updateNav() {
    $$('a.tab').forEach(function (link) {
      var target = (link.getAttribute('href') || '').replace(/^#\/?/, '');
      if (target === state.route) link.setAttribute('aria-current', 'page');
      else link.removeAttribute('aria-current');
    });
    document.title = 'XPCarData · ' + (PAGE_TITLES[state.route] || 'Remote view');
  }

  function renderCurrentPage() {
    switch (state.route) {
      case 'live':
        renderLive();
        break;
      case 'charging':
        renderSessions();
        break;
      case 'logs':
        renderLogs();
        break;
      case 'settings':
        renderSettings();
        break;
      case 'manual':
        renderManual();
        break;
      case 'about':
        renderAbout();
        break;
      default:
        renderDashboard();
    }
  }

  function showPage() {
    PAGES.forEach(function (page) {
      var section = document.getElementById('page-' + page);
      if (section) section.hidden = page !== state.route;
    });
    renderCurrentPage();
  }

  function onRouteChange() {
    var next = currentRoute();
    var changed = next !== state.route;
    state.route = next;
    updateNav();
    showPage();
    if (changed) {
      syncPolling();
      refreshForRoute();
      if (state.route === 'settings') pollFleet();
    }
  }

  /* ================================================================== *
   * Polling
   * ================================================================== */

  function clearTimer(name) {
    if (timers[name]) {
      window.clearInterval(timers[name]);
      timers[name] = null;
    }
  }

  function startTimer(name, fn, ms) {
    if (timers[name]) return;
    timers[name] = window.setInterval(fn, ms);
  }

  function authPollBlocked() {
    if (state.auth.modalOpen) return true;
    return state.auth.mutedUntil > 0 && Date.now() < state.auth.mutedUntil;
  }

  function pollState() {
    if (document.hidden || authPollBlocked()) return;
    if (inflight.state) return;
    inflight.state = true;

    api('/api/state')
      .then(function (payload) {
        var server = payload && payload.server && typeof payload.server === 'object' ? payload.server : null;
        var data = payload && payload.data && typeof payload.data === 'object' && !Array.isArray(payload.data) ? payload.data : null;
        state.server = server;
        state.data = data;
        state.dataAge = payload && isNum(payload.dataAgeSeconds) ? payload.dataAgeSeconds : null;
        state.snapshotAt = Date.now();
        state.connection = 'online';
        state.auth.denied = false;
        state.lastErrorText = null;
        recordHistory(data);
      })
      .catch(function (error) {
        handleApiFailure(error);
      })
      .then(function () {
        inflight.state = false;
        renderStatus();
        renderCurrentPage();
      });
  }

  function pollSessions() {
    if (document.hidden || state.route !== 'charging' || authPollBlocked()) return;
    if (inflight.sessions) return;
    inflight.sessions = true;

    api('/api/sessions?limit=20')
      .then(function (payload) {
        var list = payload && Array.isArray(payload.sessions) ? payload.sessions : [];
        state.sessions = list.filter(function (session) {
          return session && typeof session === 'object';
        });
        state.sessionsError = null;
        state.auth.denied = false;
      })
      .catch(function (error) {
        state.sessionsError = error;
        handleApiFailure(error);
      })
      .then(function () {
        inflight.sessions = false;
        if (state.route === 'charging') {
          renderSessions();
          renderStatus();
        }
      });
  }

  function pollLogs() {
    if (document.hidden || state.route !== 'logs' || state.logsPaused || authPollBlocked()) return;
    if (inflight.logs) return;
    inflight.logs = true;

    api('/api/logs?limit=200')
      .then(function (payload) {
        var list = payload && Array.isArray(payload.logs) ? payload.logs : [];
        state.logs = list.map(function (line) {
          return String(line);
        });
        state.logsError = null;
        state.auth.denied = false;
      })
      .catch(function (error) {
        state.logsError = error;
        handleApiFailure(error);
      })
      .then(function () {
        inflight.logs = false;
        if (state.route === 'logs') {
          renderLogs();
          renderStatus();
        }
      });
  }

  function pollSettings() {
    if (document.hidden || state.route !== 'settings' || authPollBlocked()) return;
    if (inflight.settings) return;
    inflight.settings = true;

    api('/api/settings')
      .then(function (payload) {
        state.settings = payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : null;
        state.settingsError = null;
        state.auth.denied = false;
      })
      .catch(function (error) {
        state.settingsError = error;
        handleApiFailure(error);
      })
      .then(function () {
        inflight.settings = false;
        if (state.route === 'settings') {
          renderSettings();
          renderStatus();
        }
      });
  }

  function pollFleet() {
    if (document.hidden || state.route !== 'settings' || authPollBlocked()) return;
    if (inflight.fleet) return;
    inflight.fleet = true;

    api('/api/fleet')
      .then(function (payload) {
        state.fleet = payload && typeof payload === 'object' && !Array.isArray(payload) ? payload : null;
        state.fleetError = null;
        state.fleetLoaded = true;
        state.auth.denied = false;
      })
      .catch(function (error) {
        state.fleet = null;
        state.fleetError = error;
        handleApiFailure(error);
      })
      .then(function () {
        inflight.fleet = false;
        if (state.route === 'settings') renderSettings();
      });
  }

  function pollManual() {
    if (document.hidden || state.route !== 'manual' || authPollBlocked()) return;
    if (inflight.manual) return;
    inflight.manual = true;

    api('/api/manual')
      .then(function (payload) {
        state.manual = payload && typeof payload.manual === 'string' ? payload.manual : '';
        state.manualError = null;
        state.auth.denied = false;
      })
      .catch(function (error) {
        state.manualError = error;
        handleApiFailure(error);
      })
      .then(function () {
        inflight.manual = false;
        state.manualRev += 1;
        if (state.route === 'manual') renderManual();
      });
  }

  function refreshForRoute() {
    if (document.hidden) return;
    pollState();
    if (state.route === 'charging') pollSessions();
    if (state.route === 'logs') pollLogs();
    if (state.route === 'settings') pollSettings();
    if (state.route === 'manual') pollManual();
  }

  function syncPolling() {
    var visible = !document.hidden;

    if (visible) startTimer('state', pollState, POLL_STATE_MS);
    else clearTimer('state');

    if (visible && state.route === 'charging') startTimer('sessions', pollSessions, POLL_SESSIONS_MS);
    else clearTimer('sessions');

    if (visible && state.route === 'logs') startTimer('logs', pollLogs, POLL_LOGS_MS);
    else clearTimer('logs');

    if (visible && state.route === 'settings') startTimer('settings', pollSettings, POLL_SETTINGS_MS);
    else clearTimer('settings');

    if (visible) startTimer('tick', renderStatus, 1000);
    else clearTimer('tick');
  }

  function onVisibilityChange() {
    syncPolling();
    if (!document.hidden) refreshForRoute();
  }

  /* ================================================================== *
   * Toast
   * ================================================================== */

  function toast(message) {
    var node = $('#toast');
    if (!node) return;
    node.textContent = message;
    node.hidden = false;
    if (toastTimer) window.clearTimeout(toastTimer);
    toastTimer = window.setTimeout(function () {
      node.hidden = true;
      toastTimer = null;
    }, 2200);
  }

  /* ================================================================== *
   * Event wiring
   * ================================================================== */

  function wireTabs() {
    var nav = $('#tabs');
    if (!nav) return;
    nav.addEventListener('keydown', function (event) {
      var links = $$('a.tab', nav);
      var index = links.indexOf(document.activeElement);
      if (index < 0) return;
      var next = -1;
      if (event.key === 'ArrowRight') next = (index + 1) % links.length;
      else if (event.key === 'ArrowLeft') next = (index - 1 + links.length) % links.length;
      else if (event.key === 'Home') next = 0;
      else if (event.key === 'End') next = links.length - 1;
      else return;
      event.preventDefault();
      links[next].focus();
      links[next].click();
    });

    var skip = document.getElementById('skip-link');
    if (skip) {
      skip.addEventListener('click', function (event) {
        event.preventDefault();
        var main = $('#main');
        if (!main) return;
        main.setAttribute('tabindex', '-1');
        main.focus();
        if (typeof main.scrollIntoView === 'function') {
          main.scrollIntoView({ block: 'start' });
        }
      });
    }
  }

  function wireLive() {
    var filter = $('#live-filter');
    if (filter) {
      filter.addEventListener('input', function () {
        state.liveFilter = filter.value;
        renderLive();
      });
    }
    $$('#live-table .sortbtn').forEach(function (button) {
      button.addEventListener('click', function () {
        var field = button.getAttribute('data-sort') || 'key';
        if (state.liveSort.field === field) {
          state.liveSort.dir = state.liveSort.dir === 1 ? -1 : 1;
        } else {
          state.liveSort = { field: field, dir: 1 };
        }
        renderLive();
      });
    });
  }

  function wireLogs() {
    var filter = $('#log-filter');
    if (filter) {
      filter.addEventListener('input', function () {
        state.logFilter = filter.value;
        renderLogs();
      });
    }

    var autoscroll = $('#log-autoscroll');
    if (autoscroll) {
      autoscroll.addEventListener('change', function () {
        state.autoScroll = autoscroll.checked;
        renderLogs();
      });
    }

    var pause = $('#log-pause');
    if (pause) {
      pause.addEventListener('click', function () {
        state.logsPaused = !state.logsPaused;
        renderLogs();
        if (!state.logsPaused && !document.hidden) pollLogs();
      });
    }

    var copy = $('#log-copy');
    if (copy) copy.addEventListener('click', copyLogs);
  }

  function wireToken() {
    var form = $('#token-form');
    if (form) {
      form.addEventListener('submit', function (event) {
        event.preventDefault();
        var input = $('#token-input');
        var value = input ? input.value.trim() : '';
        if (!value) {
          showTokenError('Enter the access token from the app.');
          return;
        }
        setToken(value);
        closeTokenModal();
        state.auth.denied = false;
        state.auth.mutedUntil = 0;
        renderStatus();
        renderAbout();
        refreshForRoute();
        if (state.route === 'settings') pollFleet();
        toast('Token saved');
      });
    }

    var cancel = $('#token-cancel');
    if (cancel) {
      cancel.addEventListener('click', function () {
        state.auth.mutedUntil = Date.now() + AUTH_MUTE_MS;
        closeTokenModal();
        renderStatus();
        toast('Locked — will retry in a minute');
      });
    }

    var modal = $('#token-modal');
    if (modal) {
      modal.addEventListener('keydown', function (event) {
        if (event.key === 'Escape') {
          event.preventDefault();
          if (cancel) cancel.click();
          return;
        }
        if (event.key === 'Tab') trapTab(event, modal);
      });
    }

    var change = $('#btn-change-token');
    if (change) {
      change.addEventListener('click', function () {
        showTokenModal('');
      });
    }

    var clear = $('#btn-clear-token');
    if (clear) {
      clear.addEventListener('click', function () {
        setToken('');
        state.auth.denied = false;
        state.auth.mutedUntil = 0;
        renderAbout();
        renderStatus();
        toast('Token cleared');
        if (!document.hidden) refreshForRoute();
      });
    }
  }

  /* ================================================================== *
   * Init
   * ================================================================== */

  function init() {
    wireTabs();
    wireLive();
    wireLogs();
    wireToken();

    if (!location.hash) {
      try {
        history.replaceState(null, '', '#/dashboard');
      } catch (e) {
        location.hash = '#/dashboard';
      }
    }

    state.route = currentRoute();
    updateNav();
    renderStatus();
    showPage();
    syncPolling();
    refreshForRoute();
    if (state.route === 'settings') pollFleet();

    window.addEventListener('hashchange', onRouteChange);
    document.addEventListener('visibilitychange', onVisibilityChange);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
