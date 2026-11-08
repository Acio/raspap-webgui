import { getCSRFToken } from "../helpers.js";

export function showSessionExpiredModal() {
    $('#sessionTimeoutModal').modal('show');
}

export function initSession_ajax() {
    function checkSession() {
        // skip session check if on login page
        if (window.location.pathname === '/login') {
            return;
        }
        var csrfToken = getCSRFToken();
        $.post('ajax/session/do_check_session.php',{'csrf_token': csrfToken},function (data) {
            if (data.status === 'session_expired') {
                clearInterval(sessionCheckInterval);
                showSessionExpiredModal();
            }
        }).fail(function (jqXHR, status, err) {
            // the server ended the session (idle timeout)
            if (jqXHR.status === 401) {
                clearInterval(sessionCheckInterval);
                showSessionExpiredModal();
                return;
            }
            console.error("Error checking session status:", status, err);
        });
    }
    let sessionCheckInterval = setInterval(checkSession, 5000);
}