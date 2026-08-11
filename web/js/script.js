var timer;
var request;
var failureTimer;
var navigationTimer;
var booting = false;
var portal = false;
var portalUrl = "";
var interval = 1000;
var lastStatus = "";

function abortRequest() {

    if (!request) {
        return false;
    }

    request.onreadystatechange = null;
    request.abort();
    request = null;

    return true;
}

function clearFailure() {

    if (!failureTimer) {
        return false;
    }

    clearTimeout(failureTimer);
    failureTimer = null;

    return true;
}

function connectionLost() {

    if (booting || (portal && portalUrl.length == 0) ||
        document.hidden || failureTimer) {
        return false;
    }

    failureTimer = setTimeout(function() {

        if (booting || (portal && portalUrl.length == 0) ||
            document.hidden) {
            failureTimer = null;
            return;
        }

        setStopped();
    }, interval * 3);

    return true;
}

function clearNavigation() {

    if (!navigationTimer) {
        return false;
    }

    clearTimeout(navigationTimer);
    navigationTimer = null;

    return true;
}

function visibilityChanged() {

    clearFailure();
    clearNavigation();

    if (document.hidden) {
        return false;
    }

    getInfo();
    return true;
}

function getInfo() {

    var url = "msg.html";

    try {
        abortRequest();

        if (window.XMLHttpRequest) {
            request = new XMLHttpRequest();
        } else {
            throw new Error("XMLHttpRequest not available!");
        }

        request.onreadystatechange = processInfo;
        request.open("GET", url, true);
        request.send();

    } catch (e) {
        setError("Error: " + e.message);
    }
}

function getURL() {

    var protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
    var path = window.location.pathname.replace(/[^/]*$/, '').replace(/\/$/, '');

    return protocol + "//" + window.location.host + path;
}

function redirect(url) {

    if (document.hidden || navigationTimer) {
        return false;
    }

    navigationTimer = setTimeout(function() {
        navigationTimer = null;
        window.location.assign(url);
    }, 3000);

    return true;
}

function beginPortal(url) {

    portal = true;
    portalUrl = url || "";
    booting = false;

    clearFailure();
    setInfo("Connecting to web portal", true);
    schedule();

    if (portalUrl.length > 0) {
        redirect(portalUrl);
    }

    return true;
}

function processCommand(msg) {

    if (msg == "portal") {
        return beginPortal("");
    }

    if (msg.indexOf("portal ") == 0) {
        return beginPortal(msg.substring(7));
    }

    console.warn("Unknown command: " + msg);
    return false;
}

function processMsg(msg) {

    rememberStatus(msg);
    setInfo(msg);

    return true;
}

function processInfo() {

    if (request.readyState != 4) {
        return true;
    }

    var response = request;
    request = null;

    var status = response.status;

    if (status == 502 || status == 503 || status == 504) {
        connectionLost();
        schedule();
        return true;
    }

    var msg = response.responseText;
    if (msg == null || msg.length == 0) {
        connectionLost();
        schedule();
        return false;
    }

    var notFound = (status == 404);

    if (status == 200) {
        if (msg.toLowerCase().indexOf("<html>") !== -1) {
            notFound = true;
        } else {
            clearFailure();
            processMsg(msg);

            if (portalUrl.length > 0) {
                setInfo("Connecting to web portal", true);
                redirect(portalUrl);
            } else {
                schedule();
            }

            return true;
        }
    }

    if (notFound) {
        clearFailure();
        booting = false;
        setInfo("Connecting to web portal", true);

        if (portalUrl.length > 0) {
            redirect(portalUrl);
        } else {
            portal = true;
            reload();
        }

        return true;
    }

    setError("Error: Received statuscode " + status);
    return false;
}

function extractContent(s) {
    var span = document.createElement('span');
    span.innerHTML = s;
    return span.textContent || span.innerText;
};

function escapeContent(s) {
    var span = document.createElement('span');
    span.textContent = s;
    return span.innerHTML;
}

function rememberStatus(msg) {

    var text = extractContent(msg).trim();
    if (text.length == 0) {
        return false;
    }

    if (text.includes("Booting ")) {
        booting = true;
    }

    lastStatus = text;
    return true;
}

function parseSize(value, unit) {

    var powers = {
        "B": 0,
        "KB": 1,
        "KIB": 1,
        "MB": 2,
        "MIB": 2,
        "GB": 3,
        "GIB": 3,
        "TB": 4,
        "TIB": 4,
        "PB": 5,
        "PIB": 5,
        "EB": 6,
        "EIB": 6
    };

    unit = unit.toUpperCase();

    if (!Object.prototype.hasOwnProperty.call(powers, unit)) {
        return null;
    }

    var bytes = Number(value) * Math.pow(1024, powers[unit]);

    if (!Number.isFinite(bytes) || bytes < 0) {
        return null;
    }

    return bytes;
}

function estimateProgress(bytes) {

    var boundary = 512 * 1024 * 1024;
    var previousBoundary = 0;

    while (bytes > boundary) {
        previousBoundary = boundary;
        boundary *= 2;
    }

    if (previousBoundary === 0) {
        return Math.min(bytes / boundary * 100, 99.9);
    }

    var rangeProgress =
        (bytes - previousBoundary) /
        (boundary - previousBoundary);

    return Math.min(30 + Math.pow(rangeProgress, 2) * 70, 99.9);
}

function parseProgress(msg) {

    var container = document.createElement("div");
    container.innerHTML = msg;

    var walker = document.createTreeWalker(
        container,
        NodeFilter.SHOW_TEXT
    );

    var node;
    var lastNode = null;

    while ((node = walker.nextNode())) {
        if (node.nodeValue.trim() !== "") {
            lastNode = node;
        }
    }

    if (!lastNode) {
        return {
            message: msg,
            progress: null,
            size: null
        };
    }

    var percentMatch = lastNode.nodeValue.match(
        /\s+\((\d+(?:\.\d+)?)%\)\s*$/
    );

    if (percentMatch) {
        var progress = Number(percentMatch[1]);

        if (Number.isFinite(progress) && progress >= 0 && progress <= 100) {
            lastNode.nodeValue = lastNode.nodeValue.slice(
                0,
                percentMatch.index
            );

            return {
                message: container.innerHTML,
                progress: progress,
                size: null
            };
        }
    }

    var sizeMatch = lastNode.nodeValue.match(
        /\s+\((\d+(?:\.\d+)?)\s+([KMGTPE]?i?B)\)\s*$/i
    );

    if (sizeMatch) {
        var bytes = parseSize(sizeMatch[1], sizeMatch[2]);

        if (bytes != null) {
            var size = sizeMatch[1] + " " + sizeMatch[2];

            return {
                message: msg,
                progress: estimateProgress(bytes),
                size: size
            };
        }
    }

    return {
        message: msg,
        progress: null,
        size: null
    };
}

function resizeProgress() {

    var info = document.getElementById("info");
    var progress = document.getElementById("progress");

    if (!info || !progress || progress.hidden) {
        return false;
    }

    var style = window.getComputedStyle(info);
    var measurement = document.createElement("span");

    measurement.textContent = info.innerText;
    measurement.style.position = "fixed";
    measurement.style.left = "-9999px";
    measurement.style.top = "-9999px";
    measurement.style.visibility = "hidden";
    measurement.style.whiteSpace = "nowrap";
    measurement.style.fontFamily = style.fontFamily;
    measurement.style.fontSize = style.fontSize;
    measurement.style.fontWeight = style.fontWeight;
    measurement.style.fontStyle = style.fontStyle;
    measurement.style.letterSpacing = style.letterSpacing;
    measurement.style.textTransform = style.textTransform;

    document.body.appendChild(measurement);

    var textWidth = measurement.getBoundingClientRect().width;
    var loading = info.getElementsByClassName("loading").length > 0;
    var dotsWidth = 0;

    if (loading) {
        dotsWidth = parseFloat(style.fontSize) * 0.75;
    }

    measurement.remove();

    var maximumWidth = window.innerWidth * 0.8;
    var width = Math.min(textWidth + dotsWidth + 100, maximumWidth);

    progress.style.width = width + "px";
    progress.style.transform = loading
        ? "translateX(" + (dotsWidth / 2) + "px)"
        : "";

    return true;
}

function setProgress(value, size) {

    var progress = document.getElementById("progress");
    var fill = document.getElementById("progress-fill");

    if (value == null) {
        progress.hidden = true;
        progress.removeAttribute("title");
        progress.removeAttribute("aria-valuenow");
        progress.removeAttribute("aria-valuetext");
        fill.style.width = "0%";
        return true;
    }

    progress.hidden = false;
    progress.title = size != null ? size : value + "%";
    progress.setAttribute("aria-valuenow", value);

    if (size != null) {
        progress.setAttribute("aria-valuetext", size);
    } else {
        progress.removeAttribute("aria-valuetext");
    }

    fill.style.width = value + "%";

    return true;
}

function setInfo(msg, loading, error) {

    if (msg == null || msg.length == 0) {
        return false;
    }

    var parsed = parseProgress(msg);
    msg = parsed.message;
    setProgress(parsed.progress, parsed.size);

    var el = document.getElementById("info");

    if (el.innerText == msg || el.innerHTML == msg) {
        var progressEl = document.getElementById("progress");
        if (progressEl && !progressEl.hidden && !progressEl.style.width) {
            resizeProgress();
        }
        return true;
    }

    var spin = document.getElementById("spinner");

    error = !!error;
    if (!error) {
        spin.style.visibility = 'visible';
    } else {
        spin.style.visibility = 'hidden';
    }

    var p = "<p class=\"loading\">";
    loading = !!loading;
    if (loading) {
        msg = p + msg + "</p>";
    }

    if (msg.includes(p)) {
        if (el.innerHTML.includes(p)) {
            el.getElementsByClassName('loading')[0].textContent = extractContent(msg);
            resizeProgress();
            return true;
        }
    }

    el.innerHTML = msg;
    resizeProgress();
    return true;
}

function setError(text) {
    console.warn(text);
    return setInfo(text, false, true);
}

function setStopped() {

    var msg = "<span style=\"display:block\">The container has stopped.</span>";
    msg += "<span style=\"display:block; margin-top:1em; font-size:0.85em; font-weight:normal\">Check the container log for more details.</span>";

    if (lastStatus.length > 0) {
        msg += "<span style=\"display:block; margin-top:1em; font-size:0.75em; font-weight:normal; color:rgba(255,255,255,0.65)\">[ Last status: " + escapeContent(lastStatus) + " ]</span>";
    }

    return setError(msg);
}

function schedule() {

    clearTimeout(timer);
    timer = setTimeout(getInfo, interval);
}

function reload() {

    if (document.hidden) {
        return false;
    }

    clearNavigation();

    navigationTimer = setTimeout(function() {
        navigationTimer = null;
        window.location.reload();
    }, 3000);

    return true;
}

function connect() {

    var wsUrl = getURL() + "/status";
    var ws = new WebSocket(wsUrl);

    ws.onopen = function(e) {

        clearFailure();

        if (portalUrl.length > 0) {
            redirect(portalUrl);
        }
    };

    ws.onmessage = function(e) {

        clearFailure();

        var pos = e.data.indexOf(":");
        var cmd = e.data.substring(0, pos);
        var msg = e.data.substring(pos + 2);

        switch (cmd) {
            case "s":

                if (abortRequest()) {
                    schedule();
                }

                processMsg(msg);
                break;

            case "c":

                abortRequest();
                processCommand(msg);
                break;

            case "e":

                if (abortRequest()) {
                    schedule();
                }

                rememberStatus(msg);
                setError(msg);
                break;

            default:
                console.warn("Unknown event: " + cmd);
                break;
        }
    };

    ws.onclose = function(e) {

        connectionLost();

        if (portal && portalUrl.length == 0) {
            return;
        }

        setTimeout(function() {
            connect();
        }, interval);
    };

    ws.onerror = function(e) {
        connectionLost();
        ws.close();
    };
}

window.addEventListener("resize", resizeProgress);
document.addEventListener("visibilitychange", visibilityChanged);
rememberStatus(document.getElementById("info").innerHTML);

schedule();
connect();
