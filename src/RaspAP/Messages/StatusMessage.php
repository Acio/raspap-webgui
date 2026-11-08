<?php

/**
 * Status message class
 *
 * @description Status message class for RaspAP
 * @author      Bill Zimmerman <billzimmerman@gmail.com>
 * @license     https://github.com/raspap/raspap-webgui/blob/master/LICENSE
 */

namespace RaspAP\Messages;

class StatusMessage
{
    public $messages = array();

    /**
     * Adds a status message
     *
     * Hardened fork: the message is text. The method escapes it, because a
     * message often holds request data, file content or the output of a
     * command. Only a caller that builds the HTML itself, with escaped values,
     * sets $html to true.
     *
     * @param string $message
     * @param string $level a Bootstrap alert level (success, info, warning, danger), and more classes
     * @param bool $dismissable
     * @param bool $html the message is HTML, not text
     */
    public function addMessage($message, $level = 'success', $dismissable = true, bool $html = false)
    {
        $text = _((string)$message);
        if (!$html) {
            $text = htmlspecialchars($text, ENT_QUOTES, 'UTF-8');
        }
        // CSS class names only, for example 'warning alert-persistent'
        $level = preg_replace('/[^a-z -]/', '', (string)$level);
        $status = '<div class="alert alert-'.$level;
        if ($dismissable) {
            $status .= ' alert-dismissible';
        }
        $status .= ' fade show" role="alert">'. $text;
        if ($dismissable) {
            $status .= '<button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="close"></button>';
        }
        $status .= '</div>';

        array_push($this->messages, $status);
    }

    public function showMessages($clear = true)
    {
        foreach ($this->messages as $message) {
            echo $message;
        }
        if ($clear) {
            $this->messages = array();
        }
    }
}
