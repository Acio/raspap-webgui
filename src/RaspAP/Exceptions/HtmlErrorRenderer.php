<?php

/**
 * HTML error renderer class
 *
 * @description An HTML error renderer for RaspAP
 * @author      Bill Zimmerman <billzimmerman@gmail.com>
 * @license     https://github.com/raspap/raspap-webgui/blob/master/LICENSE
 * @see
 */

declare(strict_types=1);

namespace RaspAP\Exceptions;

class HtmlErrorRenderer
{

    public function __construct()
    {
        $this->charset = 'UTF-8';
        $this->projectDir = dirname(__DIR__, 3);
        $this->template = '/templates/exception.php';
    }

    /**
     * Hardened fork: all users get a page with only the reference of the log
     * line. Only a logged-in admin user also gets the message and the trace.
     * The response has no X-Debug headers.
     */
    public function render($exception, string $reference = '')
    {
        $details = self::showDetails();
        $message = $details ? $exception->getMessage() : '';
        $code = $details ? $exception->getCode() : '';
        $file = $details ? $exception->getFile() : '';
        $line = $details ? $exception->getLine() : '';
        $trace = $details ? $this->getExceptionTraceAsString($exception) : '';

        if (!headers_sent()) {
            http_response_code(500);
            header('Content-Type: text/html; charset='.$this->charset);
            header('Cache-Control: no-store');
        }
        // the template uses the variables above ($file is the file of the
        // exception, not the template)
        ob_start();
        include $this->projectDir . $this->template;
        echo ob_get_clean();
    }

    /**
     * Hardened fork: true only when the admin user is logged in
     */
    private static function showDetails(): bool
    {
        if (session_status() !== PHP_SESSION_ACTIVE) {
            return false;
        }
        try {
            return (new \RaspAP\Auth\HTTPAuth())->isAdmin();
        } catch (\Throwable $e) {
            return false;
        }
    }

    /**
     * Improved exception trace
     * @param object $e     : exception
     * @param array $seen   : passed to recursive calls to accumulate trace lines already seen
     * @return array of strings, one entry per trace line
     * @see https://github.com/php/php-src/blob/master/Zend/zend_exceptions.c
     */
    public function getExceptionTraceAsString($e, $seen = null) {

        $starter = $seen ? 'Thrown by: ' : '';
        $result = array();
        if (!$seen) $seen = array();
        $trace  = $e->getTrace();
        $prev   = $e->getPrevious();
        $result[] = sprintf('%s%s: %s', $starter, get_class($e), $e->getMessage());
        $file = $e->getFile();
        $line = $e->getLine();

        while (true) {
            $current = "$file:$line";
            if (is_array($seen) && in_array($current, $seen)) {
                $result[] = sprintf(' ... %d more', count($trace)+1);
                break;
            }
            $result[] = sprintf(' at %s%s%s(%s%s%s)',
                count($trace) && array_key_exists('class', $trace[0]) ? str_replace('\\', '.', $trace[0]['class']) : '',
                count($trace) && array_key_exists('class', $trace[0]) && array_key_exists('function', $trace[0]) ? '.' : '',
                count($trace) && array_key_exists('function', $trace[0]) ? str_replace('\\', '.', $trace[0]['function']) : '(main)',
                $line === null ? $file : basename($file),
                $line === null ? '' : ':',
                $line === null ? '' : $line);

            if (is_array($seen)) {
                $seen[] = "$file:$line";
            }
            if (!count($trace)) {
                break;
            }
            $file = array_key_exists('file', $trace[0]) ? $trace[0]['file'] : 'Unknown Source';
            $line = array_key_exists('file', $trace[0]) && array_key_exists('line', $trace[0]) && $trace[0]['line'] ? $trace[0]['line'] : null;
            array_shift($trace);
        }
        $result = join(PHP_EOL, $result);
        if ($prev) {
            $result  .= PHP_EOL . $this->getExceptionTraceAsString($prev, $seen);
        }
        return $result;
    }

}

