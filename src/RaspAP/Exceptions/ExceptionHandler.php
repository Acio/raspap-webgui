<?php

/**
 * Exception handler class
 *
 * @description A simple exception handler for RaspAP
 * @author      Bill Zimmerman <billzimmerman@gmail.com>
 * @license     https://github.com/raspap/raspap-webgui/blob/master/LICENSE
 * @see
 */

declare(strict_types=1);

namespace RaspAP\Exceptions;

use RaspAP\Exceptions\HtmlErrorRenderer;

class ExceptionHandler
{

    public function __construct()
    {
        $this->setExceptionHandler();
        $this->setShutdownHandler();
    }

    public static function handleException($exception)
    {
        // hardened fork: a reference connects the error page to the log line
        $reference = bin2hex(random_bytes(4));
        $errorMessage = (
            '[' . date('Y-m-d H:i:s') . '] [' . $reference . '] ' .
            $exception->getMessage() . ' in ' .
            $exception->getFile() . ' on line ' .
            $exception->getLine() . PHP_EOL
        );
        // Log the exception
        self::writeLog($errorMessage);

        $renderer = new HtmlErrorRenderer();
        $renderer->render($exception, $reference);
    }

    public static function handleShutdown()
    {
        $error = error_get_last();
        if ($error !== null && in_array($error['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR])) {
            // hardened fork: the page shows this error (before, $exception was not set)
            self::handleException(new \ErrorException(
                $error['message'], 0, $error['type'], $error['file'], $error['line']
            ));
        }
    }

    /**
     * Hardened fork: writes a line to the error log. A new log file gets
     * mode 640, so only www-data and its group can read it.
     */
    private static function writeLog(string $line): void
    {
        $log = RASPI_ERROR_LOG;
        if (!file_exists($log)) {
            $umask = umask(0027);
            @touch($log);
            umask($umask);
        }
        error_log($line, 3, $log);
    }

    protected function setExceptionHandler()
    {
        set_exception_handler(array($this, 'handleException'));
    }

    protected function setShutdownHandler()
    {
        register_shutdown_function(array($this, 'handleShutdown'));
    }
}

