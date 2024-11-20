var request;
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
        var err = "Error: " + e.message;
        console.log(err);
        setError(err);
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

        var notFound = (request.status == 404);

        if (request.status == 200) {
            if (msg.toLowerCase().indexOf("<html>") !== -1) {
                notFound = true;
            } else {
                if (msg.toLowerCase().indexOf("href=") !== -1) {
                    var div = document.createElement("div");
                    div.innerHTML = msg;
                    var url = div.querySelector("a").href;
                    setTimeout(() => {
                        window.location.assign(url);
                    }, 3000);
                    setInfo(msg);
                    return true;
                } else {
                    setInfo(msg);
                    schedule();
                    return true;
                }
            }
        }

        if (notFound) {
            setInfo("Connecting to web portal", true);
            reload();
            return true;
        }

        setError("Error: Received statuscode " + request.status);
        schedule();
        return false;

    } catch (e) {
        var err = "Error: " + e.message;
        console.log(err);
        setError(err);
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
            msg = "<p class=\"loading\">" + msg + "</p>";
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
