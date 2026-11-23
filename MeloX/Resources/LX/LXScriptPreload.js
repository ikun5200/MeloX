(function () {
  'use strict';

  const native = {
    send: globalThis.__lxSend,
    request: globalThis.__lxRequest,
    cancel: globalThis.__lxCancel,
    log: globalThis.__lxLog,
    resolveMusic: globalThis.__lxResolveMusic,
    setTimer: globalThis.__lxSetTimeout,
    clearTimer: globalThis.__lxClearTimeout,
    md5: globalThis.__lxMD5,
    randomBytes: globalThis.__lxRandomBytes
  };

  delete globalThis.__lxSend;
  delete globalThis.__lxRequest;
  delete globalThis.__lxCancel;
  delete globalThis.__lxLog;
  delete globalThis.__lxResolveMusic;
  delete globalThis.__lxSetTimeout;
  delete globalThis.__lxClearTimeout;
  delete globalThis.__lxMD5;
  delete globalThis.__lxRandomBytes;

  const EVENT_NAMES = {
    request: 'request',
    inited: 'inited',
    updateAlert: 'updateAlert'
  };

  const handlers = Object.create(null);
  const pendingHTTP = Object.create(null);
  const pendingMusic = Object.create(null);
  const pendingTimers = Object.create(null);
  let sequence = 0;

  function parseJSON(value, fallback) {
    if (value === undefined || value === null || value === '') return fallback;
    if (typeof value !== 'string') return value;
    try { return JSON.parse(value); } catch (_) { return fallback; }
  }

  function toBytes(value) {
    if (value instanceof Uint8Array) return value;
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (Array.isArray(value)) return new Uint8Array(value);
    if (value && typeof value.byteLength === 'number') {
      return new Uint8Array(value);
    }
    return new Uint8Array(0);
  }

  function utf8ToBytes(text) {
    const value = String(text);
    const bytes = [];
    for (let index = 0; index < value.length; index += 1) {
      let code = value.codePointAt(index);
      if (code > 0xffff) index += 1;
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xc0 | (code >> 6));
        bytes.push(0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        bytes.push(0xe0 | (code >> 12));
        bytes.push(0x80 | ((code >> 6) & 0x3f));
        bytes.push(0x80 | (code & 0x3f));
      } else {
        bytes.push(0xf0 | (code >> 18));
        bytes.push(0x80 | ((code >> 12) & 0x3f));
        bytes.push(0x80 | ((code >> 6) & 0x3f));
        bytes.push(0x80 | (code & 0x3f));
      }
    }
    return new Uint8Array(bytes);
  }

  function bytesToUtf8(input) {
    const bytes = toBytes(input);
    let output = '';
    for (let index = 0; index < bytes.length;) {
      const first = bytes[index++];
      if (first < 0x80) {
        output += String.fromCharCode(first);
      } else if (first < 0xe0) {
        output += String.fromCharCode(
          ((first & 0x1f) << 6) | (bytes[index++] & 0x3f)
        );
      } else if (first < 0xf0) {
        output += String.fromCharCode(
          ((first & 0x0f) << 12) |
          ((bytes[index++] & 0x3f) << 6) |
          (bytes[index++] & 0x3f)
        );
      } else {
        const codePoint = (
          ((first & 0x07) << 18) |
          ((bytes[index++] & 0x3f) << 12) |
          ((bytes[index++] & 0x3f) << 6) |
          (bytes[index++] & 0x3f)
        );
        output += String.fromCodePoint(codePoint);
      }
    }
    return output;
  }

  const BASE64_CHARS =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function bytesToBase64(input) {
    const bytes = toBytes(input);
    let output = '';
    for (let index = 0; index < bytes.length; index += 3) {
      const first = bytes[index];
      const second = index + 1 < bytes.length ? bytes[index + 1] : 0;
      const third = index + 2 < bytes.length ? bytes[index + 2] : 0;
      output += BASE64_CHARS[first >> 2];
      output += BASE64_CHARS[((first & 0x03) << 4) | (second >> 4)];
      output += index + 1 < bytes.length
        ? BASE64_CHARS[((second & 0x0f) << 2) | (third >> 6)]
        : '=';
      output += index + 2 < bytes.length
        ? BASE64_CHARS[third & 0x3f]
        : '=';
    }
    return output;
  }

  function base64ToBytes(value) {
    const input = String(value).replace(/[^A-Za-z0-9+/=]/g, '');
    const bytes = [];
    for (let index = 0; index < input.length; index += 4) {
      const first = BASE64_CHARS.indexOf(input[index]);
      const second = BASE64_CHARS.indexOf(input[index + 1]);
      const third = input[index + 2] === '='
        ? -1
        : BASE64_CHARS.indexOf(input[index + 2]);
      const fourth = input[index + 3] === '='
        ? -1
        : BASE64_CHARS.indexOf(input[index + 3]);
      bytes.push((first << 2) | (second >> 4));
      if (third >= 0) bytes.push(((second & 0x0f) << 4) | (third >> 2));
      if (fourth >= 0) bytes.push(((third & 0x03) << 6) | fourth);
    }
    return new Uint8Array(bytes);
  }

  function bytesToHex(input) {
    return Array.prototype.map.call(toBytes(input), function (byte) {
      return byte.toString(16).padStart(2, '0');
    }).join('');
  }

  function hexToBytes(value) {
    const text = String(value);
    const bytes = [];
    for (let index = 0; index + 1 < text.length; index += 2) {
      bytes.push(parseInt(text.slice(index, index + 2), 16));
    }
    return new Uint8Array(bytes);
  }

  function bufferFrom(input, encoding) {
    if (typeof input === 'string') {
      const format = String(encoding || 'utf8').toLowerCase();
      if (format === 'hex') return hexToBytes(input);
      if (format === 'base64') return base64ToBytes(input);
      return utf8ToBytes(input);
    }
    return toBytes(input);
  }

  function bufferToString(input, format) {
    const kind = String(format || 'utf8').toLowerCase();
    if (kind === 'hex') return bytesToHex(input);
    if (kind === 'base64') return bytesToBase64(input);
    return bytesToUtf8(input);
  }

  function on(event, handler) {
    if (typeof handler !== 'function') {
      throw new TypeError('lx.on handler must be a function');
    }
    handlers[event] = handler;
  }

  function send(event, data) {
    native.send(event, JSON.stringify(data === undefined ? {} : data));
  }

  function request(url, options, callback) {
    const requestID = 'http_' + (++sequence);
    pendingHTTP[requestID] = callback;
    native.request(
      requestID,
      String(url),
      JSON.stringify(options || {})
    );
    return function cancel() {
      delete pendingHTTP[requestID];
      native.cancel(requestID);
    };
  }

  globalThis.__lxOnResponse = function (requestID, error, responseText) {
    const callback = pendingHTTP[requestID];
    if (!callback) return;
    delete pendingHTTP[requestID];
    const response = parseJSON(responseText, null);
    const body = response ? response.body : null;
    try {
      if (error) callback(new Error(error), response, body);
      else callback(null, response, body);
    } catch (exception) {
      native.log('error', String(exception));
    }
  };

  globalThis.__lxRequestMusicUrl = function (
    requestID,
    source,
    quality,
    musicInfoText
  ) {
    const handler = handlers[EVENT_NAMES.request];
    Promise.resolve().then(function () {
      if (!handler) {
        throw new Error('source did not register a request handler');
      }
      return handler({
        source: source,
        action: 'musicUrl',
        info: {
          type: quality,
          musicInfo: parseJSON(musicInfoText, {})
        }
      });
    }).then(function (result) {
      if (typeof result !== 'string' || result.length === 0) {
        native.resolveMusic(
          requestID,
          'source returned an empty music URL',
          ''
        );
        return;
      }
      native.resolveMusic(requestID, '', result);
    }, function (error) {
      native.resolveMusic(
        requestID,
        String((error && error.message) || error || 'unknown error'),
        ''
      );
    });
  };

  globalThis.__lxTimerFired = function (timerID) {
    const handler = pendingTimers[timerID];
    if (!handler) return;
    delete pendingTimers[timerID];
    try { handler(); } catch (exception) {
      native.log('error', String(exception));
    }
  };

  globalThis.setTimeout = function (handler, delay) {
    const timerID = 'timer_' + (++sequence);
    pendingTimers[timerID] = handler;
    native.setTimer(timerID, Math.max(0, Number(delay) || 0));
    return timerID;
  };

  globalThis.clearTimeout = function (timerID) {
    delete pendingTimers[timerID];
    native.clearTimer(timerID);
  };

  globalThis.lx = {
    EVENT_NAMES: EVENT_NAMES,
    version: '2.0.0',
    env: 'mobile',
    currentScriptInfo: parseJSON(globalThis.__lxScriptInfoJSON, {}),
    on: on,
    send: send,
    request: request,
    utils: {
      buffer: {
        from: bufferFrom,
        bufToString: bufferToString
      },
      crypto: {
        md5: function (value) {
          return native.md5(String(value));
        },
        randomBytes: function (size) {
          return new Uint8Array(native.randomBytes(Number(size) || 0));
        },
        aesEncrypt: function () {
          throw new Error('lx.utils.crypto.aesEncrypt is not supported yet');
        },
        rsaEncrypt: function () {
          throw new Error('lx.utils.crypto.rsaEncrypt is not supported yet');
        }
      }
    }
  };

  globalThis.console = globalThis.console || {};
  ['log', 'info', 'warn', 'error'].forEach(function (level) {
    globalThis.console[level] = function () {
      native.log(level, Array.prototype.map.call(arguments, function (value) {
        if (typeof value === 'string') return value;
        try { return JSON.stringify(value); } catch (_) { return String(value); }
      }).join(' '));
    };
  });

  if (!globalThis.atob) {
    globalThis.atob = function (value) {
      return bytesToUtf8(base64ToBytes(value));
    };
  }
  if (!globalThis.btoa) {
    globalThis.btoa = function (value) {
      return bytesToBase64(utf8ToBytes(value));
    };
  }
  if (!globalThis.TextEncoder) {
    globalThis.TextEncoder = function () {};
    globalThis.TextEncoder.prototype.encode = function (value) {
      return utf8ToBytes(value);
    };
  }
  if (!globalThis.TextDecoder) {
    globalThis.TextDecoder = function () {};
    globalThis.TextDecoder.prototype.decode = function (value) {
      return bytesToUtf8(value);
    };
  }
})();
