var request;
var booting = false;
var interval = 1000;

function getInfo() {

    var url = "msg.html";

    try {
        if (window.XMLHttpRequest) {
            request = new XMLHttpRequest();
        } else {
            throw "XMLHttpRequest not available!";
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

function processMsg(msg) {

    if (msg.toLowerCase().indexOf("href=") !== -1) {
        var div = document.createElement("div");
        div.innerHTML = msg;
        var url = div.querySelector("a").href;
        setTimeout(() => {
            window.location.assign(url);
        }, 3000);
    }

    setInfo(msg);
    return true;
}

function processInfo() {
    try {

        if (request.readyState != 4) {
            return true;
        }

        var msg = request.responseText;
        if (msg == null || msg.length == 0) {

            if (booting) {
                schedule();
                return true;
            }

            document.location.reload();
            return false;
        }

        var notFound = (request.status == 404);

        if (request.status == 200) {
            if (msg.toLowerCase().indexOf("<html>") !== -1) {
                notFound = true;
            } else {
                processMsg(msg);
                if (msg.toLowerCase().indexOf("href=") == -1) {
                    schedule();
                }
                return true;
            }
        }

        if (notFound) {
            setInfo("Connecting to web portal", true);
            reload();
            return true;
        }

        setError("Error: Received statuscode " + request.status);
        return false;

    } catch (e) {
        setError("Error: " + e.message);
        return false;
    }
}

function setInfo(msg, loading, error) {
    try {

        if (msg == null || msg.length == 0) {
            return false;
        }

        if (msg.includes("Booting ")) {
            booting = true;
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

        loading = !!loading;
        if (loading) {
            msg = "<p class=\"loading\">" + msg + "</p>";
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

function reload() {
    setTimeout(() => {
        document.location.reload();
    }, 3000);
}

function schedule() {
    setTimeout(getInfo, interval);
}

function connect() {

    var wsUrl = getURL() + "/status";
    var ws = new WebSocket(wsUrl);

    ws.onmessage = function(e) {

        var pos = e.data.indexOf(":");
        var cmd = e.data.substring(0, pos);
        var msg = e.data.substring(pos + 2);

        switch (cmd) {
            case "s":
                processMsg(msg);
                break;
            case "e":
                setError(msg);
                break;
            default:
                console.warn("Unknown event: " + cmd);
                break;
        }
    };

    ws.onclose = function(e) {
        setTimeout(function() {
            connect();
        }, interval);
    };

    ws.onerror = function(e) {
        ws.close();
        if (!booting) {
            document.location.reload();
        }
    };
}

schedule();
connect();
