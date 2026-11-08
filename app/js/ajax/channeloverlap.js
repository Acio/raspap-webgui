import { getCSRFToken } from "../helpers.js";

// Hardened fork: warns when the hotspot and the wireless uplink use the same
// or near frequencies. The two radios of the device then disturb each other,
// and traffic through the hotspot is slow. The uplink channel changes when
// the device connects to another network, so the page checks again.
const CHECK_INTERVAL_MS = 60 * 1000;

// the alert that the user closed, so it does not come back on this page
let closedKey = null;

function radio(r) {
    return r.iface + ', channel ' + r.channel + ', ' + r.width;
}

function showAlert(data) {
    const key = [data.status, data.ap.iface, data.ap.channel, data.uplink.iface, data.uplink.channel].join('|');
    if (key === closedKey || $('#channel-alert').data('key') === key) {
        return;
    }
    $('#channel-alert').remove();
    let text = 'The hotspot (' + radio(data.ap) + ') and the uplink (' + radio(data.uplink) + ') ';
    if (data.status === 'overlap') {
        text += 'use the same frequencies. The two radios disturb each other, and internet through the hotspot is slow.';
    } else {
        text += 'are only ' + data.gap + ' MHz apart. The two radios can disturb each other.';
    }
    if (data.suggest) {
        text += ' Set the hotspot channel to ' + data.suggest.channel +
            ' (maximum ' + data.suggest.dBm + ' dBm) on the Hotspot page.';
    } else {
        text += ' Set the hotspot to a channel far from channel ' + data.uplink.channel + '.';
    }
    const alert = $('<div class="alert alert-dismissible alert-persistent" role="alert" id="channel-alert"></div>')
        .addClass(data.status === 'overlap' ? 'alert-danger' : 'alert-warning')
        .data('key', key)
        .append($('<i class="fas fa-wifi me-2"></i>'))
        .append($('<span></span>').text(text))
        .append($('<button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Close"></button>'));
    if (window.location.pathname !== '/hostapd_conf') {
        alert.append($('<div class="mt-2"></div>').append(
            $('<a class="btn btn-sm btn-outline-secondary" href="hostapd_conf"></a>').text('Hotspot settings')));
    }
    alert.on('closed.bs.alert', function () {
        closedKey = key;
    });
    $('#layoutSidenav_content main .container-fluid').first().prepend(alert);
}

function check() {
    $.post('ajax/networking/get_channel_overlap.php', { csrf_token: getCSRFToken() }, null, 'json')
        .done(function (data) {
            if (data.status === 'overlap' || data.status === 'close') {
                showAlert(data);
            } else {
                $('#channel-alert').remove();
            }
        });
}

export function initChannelOverlap_ajax() {
    check();
    setInterval(check, CHECK_INTERVAL_MS);
}
