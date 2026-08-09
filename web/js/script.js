var timer;
var request;
var failureTimer;
var navigationTimer;
var booting = false;
var portal = false;
var portalUrl = "";
var interval = 1000;
var lastStatus = "";
var stopped = "The container has stopped. Check the container logs for details.";

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

    if (document.hidden) {
        return false;
    }

    clearNavigation();

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

    if (portalUrl.length > 0) {
        redirect(portalUrl);
    } else {
        schedule();
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
    try {

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

    } catch (e) {
        setError("Error: " + e.message);
        return false;
    }
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

function setInfo(msg, loading, error) {
    try {

        if (msg == null || msg.length == 0) {
            return false;
        }

        var el = document.getElementById("info");

        if (el.innerText == msg || el.innerHTML == msg) {
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
                return true;
            }
        }

        el.innerHTML = msg;
        return true;

    } catch (e) {
        console.log("Error: " + e.message);
        return false;
    }
}

function setError(text) {
    console.warn(text);
    return setInfo(text, false, true);
}

function setStopped() {

    var msg = stopped;
    if (lastStatus.length > 0) {
        msg += "<br>(Last status: " + escapeContent(lastStatus) + ")";
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

        if (portalUrl.length > 0) {
            clearNavigation();
        }

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

document.addEventListener("visibilitychange", visibilityChanged);
rememberStatus(document.getElementById("info").innerHTML);

schedule();
connect();
