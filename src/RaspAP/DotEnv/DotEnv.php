<?php

/**
 * DotEnv parser/writer class
 *
 * @description Reads and sets key/value pairs to .env
 * @author      Bill Zimmerman <billzimmerman@gmail.com>
 * @license     https://github.com/raspap/raspap-webgui/blob/master/LICENSE
 */

declare(strict_types=1);

namespace RaspAP\DotEnv;

class DotEnv
{
    protected $envFile;
    protected $data = [];

    public function __construct($envFile = RASPI_CONFIG_API. '/.env')
    {
        $this->envFile = $envFile;
    }

    public function load()
    {
        if (!file_exists($this->envFile)) {
            $this->createEnv();
        }

        if (file_exists($this->envFile)) {
            $this->data = parse_ini_file($this->envFile);
            foreach ($this->data as $key => $value) {
                if (!getenv($key)) {
                    putenv("$key=$value");
                    $_ENV[$key] = $value;
                }
            }
        } else {
            $this->data = [];
        }
    }

    public function set($key, $value)
    {
        $this->data[$key] = $value;
        putenv("$key=$value");
        $this->store($key, $value);
    }

    public function get($key)
    {
        return getenv($key);
    }

    public function getAll()
    {
        return $this->data;
    }

    public function unset($key)
    {
        unset($_ENV[$key]);
        return $this;
    }

    /**
     * Saves the RestAPI key with the root helper raspap-api-key.sh. The key
     * goes on stdin, so it is not in the process list. The helper checks the
     * key and writes .env as root:www-data 640. The hardened fork: www-data
     * no longer moves a file of its own to .env.
     */
    private function store($key, $value)
    {
        if ($key !== 'RASPAP_API_KEY') {
            throw new \Exception("Unable to save $key: only RASPAP_API_KEY is supported");
        }
        $proc = proc_open(
            ['sudo', '/usr/local/sbin/raspap-api-key.sh', 'set'],
            [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
            $pipes
        );
        if (!is_resource($proc)) {
            throw new \Exception('Unable to start the RestAPI key helper');
        }
        fwrite($pipes[0], $value."\n");
        fclose($pipes[0]);
        stream_get_contents($pipes[1]);
        $error = trim((string)stream_get_contents($pipes[2]));
        fclose($pipes[1]);
        fclose($pipes[2]);
        if (proc_close($proc) !== 0) {
            throw new \Exception('Unable to save the API key: '.$error);
        }
    }

    protected function createEnv()
    {
        // the installer makes .env with a key. Without .env there is no key,
        // and the helper makes the file when a key is saved.
    }
}

