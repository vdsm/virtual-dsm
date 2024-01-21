var request;
var interval = 1000;

function getInfo() {

    var url = "/msg.html";

    if (window.XMLHttpRequest) {
        request = new XMLHttpRequest();
    } else if (window.ActiveXObject) {
        request = new ActiveXObject("Microsoft.XMLHTTP");
    }

    try {
        request.onreadystatechange = processInfo;
        request.open("GET", url, true);
        request.send();
    } catch (e) {
        var err = "Error: " + e.message;
        console.log(err);
        setError(err);
        reload();
    }
}

function processInfo() {
    try {
        if (request.readyState != 4) {
            return true;
        }

        var msg = request.responseText;
        if (msg == null || msg.length == 0) {
            setInfo("Booting DSM instance", true);
            schedule();
            return false;
        }

        if (request.status == 200) {
            setInfo(msg);
            schedule();
            return true;
        }

        if (request.status == 404) {
            setInfo("Connecting to web portal", true);
            reload();
            return true;
        }

        setError("Error: Received status " + request.status);
        schedule();
        return false;

    } catch (e) {
        var err = "Error: " + e.message;
        console.log(err);
        setError(err);
        reload();
        return false;
    }
}

function setInfo(msg, loading, error) {

    try {
        if (msg == null || msg.length == 0) {
            return false;
        }

        var el = document.getElementById("spinner");

        error = !!error;
        if (!error) {
            el.style.visibility = 'visible';
        } else {
            el.style.visibility = 'hidden';
        }

        loading = !!loading;
        if (loading) {
            msg = "<p class=\"loading\">" + msg + "</p>"
        }

        el = document.getElementById("info");

        if (el.innerHTML != msg) {
            el.innerHTML = msg;
        }

        return true;

    } catch (e) {
        console.log("Error: " + e.message);
        return false;
    }
}

function setError(text) {
    return setInfo(text, false, true);
}

function schedule() {
    setTimeout(getInfo, interval);
}

function reload() {
    setTimeout(() => {
        document.location.reload();
    }, 3000);
}

schedule();
