<?php

/**
 * NTP Server Plugin
 *
 * @description A Network Time Protocol (NTP) server for RaspAP 
 * @author      Bill Zimmerman <billzimmerman@gmail.com>
 * @license     https://github.com/RaspAP/raspap-insiders/blob/master/LICENSE
 *
 * Hardened fork: the plugin writes ntp.conf and controls ntpd only through
 * the root helper /usr/local/sbin/raspap-ntp.sh. Before, it wrote
 * /tmp/ntpdata and copied that file to ntp.conf as root.
 * @see         src/RaspAP/Plugins/PluginInterface.php
 * @see         src/RaspAP/UI/Sidebar.php
 */

namespace RaspAP\Plugins\NTPServer;

use RaspAP\Plugins\PluginInterface;
use RaspAP\UI\Sidebar;

class NTPServer implements PluginInterface
{

    private string $pluginPath;
    private string $pluginName;
    private string $templateMain;
    private string $serviceStatus;
    private string $ntpConfig;
    private const HELPER = '/usr/local/sbin/raspap-ntp.sh';

    public function __construct(string $pluginPath, string $pluginName)
    {
        $this->pluginPath = $pluginPath;
        $this->pluginName = $pluginName;
        $this->templateMain = 'main';
        $this->ntpConfig = '/etc/ntpsec/ntp.conf';
     }

    /**
     * Initializes NTP plugin and creates a custom sidebar item
     *
     * @param Sidebar $sidebar an instance of the Sidebar
     * @see src/RaspAP/UI/Sidebar.php
     * @see https://fontawesome.com/icons
     */
    public function initialize(Sidebar $sidebar): void
    {

        $label = _('NTP Server');
        $icon = 'far fa-clock';
        $action = 'plugin__'.$this->getName();
        $priority = 72;
        $sidebar->addItem($label, $icon, $action, $priority);
    }

    /**
     * Handles a page action by processing inputs and rendering a plugin template
     *
     * @param string $page the current page route
     */
    public function handlePageAction(string $page): bool
    {
        // Verify that this plugin should handle the page
        if (strpos($page, "/plugin__" . $this->getName()) === 0) {

            // Instantiate a StatusMessage object
            $status = new \RaspAP\Messages\StatusMessage;

            if (!RASPI_MONITOR_ENABLED) {
                if (isset($_POST['SaveNTPsettings'])) {
                    if(isset($_POST['ntpconfigedit']) && $_POST['ntpconfigedit'] == '1') {
                        $config = trim($_POST['txtntpconfigraw']);
                        if (empty($config)) {
                            $status->addMessage('NTP configuration cannot be empty', 'danger');
                        } else {
                            $return = $this->saveNTPConfigRaw($status, $config);
                            if ($return == 0) {
                                $status->addMessage('Restarting ntpd.service', 'info');
                                $this->runHelper('restart');
                            }
                        }
                    } elseif (isset($_POST['server'])) {
                        $servers = $_POST['server'];
                        if (count($servers) == 0) {
                            $status->addMessage('Please enter a valid NTP server', 'danger');
                        } else {
                            $return = $this->saveNTPSettings($status, $servers);
                            if ($return == 0) {
                              $status->addMessage('Restarting ntpd.service', 'info');
                              $this->runHelper('restart');
                            }
                        }
                    }
                } elseif (isset($_POST['StartNTPservice'])) {
                    $status->addMessage('Attempting to start ntpd.service', 'info');
                    $return = $this->runHelper('start');
                    foreach ($return as $line) {
                        $status->addMessage($line, 'info');
                    }
                } elseif (isset($_POST['StopNTPservice'])) {
                    $status->addMessage('Attempting to stop ntpd.service', 'info');
                    $return = $this->runHelper('stop');
                    foreach ($return as $line) {
                        $status->addMessage($line, 'info');
                    }
                }
            }
            $ntpServers = [];
            exec('cat '.$this->ntpConfig, $ntpConfig);
            foreach ($ntpConfig as $line) {
                if (strpos($line, 'server') === 0) {
                    $server = trim(substr($line, strlen('server')));
                    $ntpServers[] = $server;
                }
            };
            exec("ntpd -V", $version);
            $ntpDaemon = $version[0];
            $ntpTime = shell_exec("ntptime");
            $ntpConfig = implode("\n", $ntpConfig);

            exec("pidof ntpd | wc -l", $ntpstatus);
            $serviceStatus = $ntpstatus[0] == 0 ? "down" : "up";

            $serviceLog = implode("\n", $this->runHelper('peers'));

            // Populate template data
            $__template_data = [
                'title' => _('NTP Server'),
                'description' => _('A Network Time Protocol (NTP) server for RaspAP'),
                'author' => _('Bill Z'),
                'uri' => 'https://github.com/RaspAP/raspap-insiders',
                'icon' => 'far fa-clock',
                'serviceStatus' => $serviceStatus,
                'serviceName' => 'ntpd.service',
                'ntpServers' => $ntpServers,
                'ntpDaemon' => $ntpDaemon,
                'ntpTime' => $ntpTime,
                'ntpConfig' => $ntpConfig,
                'serviceLog' => $serviceLog,
                'action' => 'plugin__'.$this->getName(),
                'pluginName' => $this->getName()
            ];
            echo $this->renderTemplate($this->templateMain, compact(
                "status",
                "__template_data"
            ));
            return true;
        }
        return false;
    }

    /**
     * Renders a template from inside a plugin directory
     * @param string $templateName
     * @param array $__data
     */
    public function renderTemplate(string $templateName, array $__data = []): string
    {
        $templateFile = "{$this->pluginPath}/{$this->getName()}/templates/{$templateName}.php";

        if (!file_exists($templateFile)) {
            return "Template file {$templateFile} not found.";
        }
        if (!empty($__data)) {
            extract($__data);
        }
        ob_start();
        include $templateFile;
        return ob_get_clean();
    }

    /**
     * Persist user settings to NTP config
     *
     * @param object $status
     * @param array $servers
     * @param string $ntpconfig
     * @return boolean
     */
    protected function saveNTPSettings($status, $servers)
    {
        exec('cat '.$this->ntpConfig, $ntpconfig);
        if (empty($ntpconfig)) {
            $status->addMessage(sprintf(_('NTP configuration not found at %s'), $this->ntpConfig), 'danger');
            return false;
        }
        $ntpconfig = array_filter($ntpconfig, function ($line) {
            return strpos(trim($line), 'server ') !== 0;
        });
        $servers = array_map(function ($server) {
            return 'server ' . trim($server);
        }, $servers);
        $ntpconfig = array_merge($ntpconfig, $servers);
        $ntpconfig = implode("\n", $ntpconfig);
        return $this->installConfig($status, $ntpconfig);
    }

    /**
     * Persist raw NTP config
     *
     * @param object $status
     * @param array $ntpconfig
     * @return boolean
     */
    protected function saveNTPConfigRaw($status, $ntpconfig)
    {
        return $this->installConfig($status, $ntpconfig);
    }

    /**
     * Installs ntp.conf through the root helper. The helper checks each line
     * and keeps the current ntp.conf when it refuses the configuration.
     *
     * @param object $status
     * @param string $ntpconfig
     * @return int 0 on success
     */
    private function installConfig($status, string $ntpconfig): int
    {
        $proc = proc_open(
            ['sudo', self::HELPER, 'install'],
            [0 => ['pipe', 'r'], 1 => ['file', '/dev/null', 'w'], 2 => ['pipe', 'w']],
            $pipes
        );
        if (!is_resource($proc)) {
            $status->addMessage('Unable to start the NTP helper', 'danger');
            return 1;
        }
        fwrite($pipes[0], rtrim($ntpconfig, "\n") . "\n");
        fclose($pipes[0]);
        $error = trim((string)stream_get_contents($pipes[2]));
        fclose($pipes[2]);
        $result = proc_close($proc);
        if ($result == 0) {
            $status->addMessage('NTP configuration updated', 'success');
        } else {
            foreach (explode("\n", $error) as $line) {
                if ($line !== '') {
                    $status->addMessage($line, 'danger');
                }
            }
        }
        return $result;
    }

    /**
     * Runs the root helper with one fixed command
     *
     * @param string $command start, stop, restart or peers
     * @return array the output lines
     */
    private function runHelper(string $command): array
    {
        $output = [];
        exec('sudo ' . self::HELPER . ' ' . escapeshellarg($command) . ' 2>&1', $output);
        return $output;
    }

    // Returns an abbreviated class name
    public static function getName(): string
    {
        return basename(str_replace('\\', '/', static::class));
    }
}

