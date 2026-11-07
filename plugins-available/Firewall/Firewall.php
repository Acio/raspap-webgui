<?php

/**
 * Firewall Plugin
 *
 * @description A Firewall plugin that implements an iptables rule set
 * @author      zbchristian <christian@zeitnitz.de>
 * @author      Bill Zimmerman <billzimmerman@gmail.com>
 * @license     https://github.com/RaspAP/raspap-insiders/blob/master/LICENSE
 * @see         src/RaspAP/Plugins/PluginInterface.php
 * @see         src/RaspAP/UI/Sidebar.php
 *
 * Changed for the hardened fork (Acio/raspap-webgui), 2026-11-06: the root
 * helper /usr/local/sbin/raspap-firewall.sh applies the rules in own chains.
 * The plugin does not run scripts from /tmp as root, and it does not flush
 * the rules of other parts of RaspAP.
 */

namespace RaspAP\Plugins\Firewall;

use RaspAP\Networking\Hotspot\WiFiManager;
use RaspAP\Networking\DeviceScanner;
use RaspAP\Plugins\PluginInterface;
use RaspAP\UI\Sidebar;

class Firewall implements PluginInterface
{

    private string $pluginPath;
    private string $pluginName;
    private string $templateMain;
    private string $serviceStatus;
    private string $firewallHelper;
    private string $firewallConfig;

    public function __construct(string $pluginPath, string $pluginName)
    {
        $this->pluginPath = $pluginPath;
        $this->pluginName = $pluginName;
        $this->templateMain = 'main';
        $this->firewallHelper = '/usr/local/sbin/raspap-firewall.sh';
        $this->firewallConfig = RASPI_CONFIG.'/networking/firewall.conf';
     }

    /**
     * Initializes Firewall plugin and creates a custom sidebar item
     *
     * @param Sidebar $sidebar an instance of the Sidebar
     * @see src/RaspAP/UI/Sidebar.php
     * @see https://fontawesome.com/icons
     */
    public function initialize(Sidebar $sidebar): void
    {

        $label = _('Firewall');
        $icon = 'fas fa-fire-alt';
        $action = 'plugin__'.$this->getName();
        $priority = 71;
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
                
                $fw_conf = $this->getFirewallConfiguration();
                $ap_device = $fw_conf["ap-device"];
                $str_clients = $fw_conf["client-list"];

                if (!empty($_POST)) {
                    $fw_action = $_POST['firewall-action'];
                    $fw_conf["ssh-enable"] = isset($_POST['ssh-enable']);
                    $fw_conf["http-enable"] = isset($_POST['http-enable']);
                    if ($fw_action === 'firewall-enable' || isset($_POST['apply-firewall'])) {
                        $fw_conf["firewall-enable"] = true;
                        $status->addMessage(_('Firewall is now enabled'), 'success');
                    } else {
                        $fw_conf["firewall-enable"] = false;
                        $status->addMessage(_('Firewall is now disabled'), 'warning');
                    }
                    if (isset($_POST['apply-firewall']) ) {
                        $status->addMessage(_('Firewall settings changed'), 'success');
                    }
                    if (isset($_POST['save-firewall']) ) {
                        $status->addMessage(_('Firewall settings saved. Firewall is still disabled.'), 'success');
                    }
                    if (isset($_POST['excl-devices'])  ) {
                        $excl = str_replace(',', ' ', (string)$_POST['excl-devices']);
                        $excl = trim(preg_replace('/\s+/', ' ', $excl));
                        $devices = [];
                        foreach (($excl === '' ? [] : explode(' ', $excl)) as $dev) {
                            if (preg_match('/^[A-Za-z0-9_.-]{1,15}\+?$/', $dev)) {
                                $devices[] = $dev;
                            } else {
                                $status->addMessage(sprintf(_('Exclude device %s failed - not a valid interface name'), htmlspecialchars($dev, ENT_QUOTES)), 'warning');
                            }
                        }
                        $excl = implode(' ', $devices);
                        if ($fw_conf["excl-devices"] != $excl ) {
                            $status->addMessage(_('Exclude devices '. $excl), 'success');
                            $fw_conf["excl-devices"] = $excl;
                        }
                    }
                    if (isset($_POST['excluded-ips'])  ) {
                        $excl = str_replace(',', ' ', (string)$_POST['excluded-ips']);
                        $excl = trim(preg_replace('/\s+/', ' ', $excl));
                        $str_excl = "";
                        if (!empty($excl) ) {
                            $excl = explode(' ', $excl);
                            foreach ( $excl as $ip ) {
                                // the firewall rules for addresses are IPv4 only
                                if (filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV4) ) { $str_excl .= "$ip ";
                                } else {
                                    $status->addMessage(sprintf(_('Exclude IP address %s failed - not a valid IPv4 address'), htmlspecialchars($ip, ENT_QUOTES)), 'warning');
                                }
                            }
                        }
                        $str_excl = trim($str_excl);
                        if ($fw_conf["excluded-ips"] != $str_excl ) {
                             $status->addMessage(_('Exclude IP address(es) '. $str_excl), 'success');
                             $fw_conf["excluded-ips"] = $str_excl;
                        }
                    }
                    $this->WriteFirewallConf($fw_conf);
                    if (!$this->configureFirewall($output)) {
                        $status->addMessage(_('Unable to apply the firewall rules'), 'danger');
                    }
                    foreach ($output as $line) {
                        if (strpos($line, 'Ignored') === 0) {
                            $status->addMessage(htmlspecialchars($line, ENT_QUOTES), 'warning');
                        }
                    }
                }
                $serviceStatus = $fw_conf["firewall-enable"] == null ? "down" : "up";

                // Populate template data
                $__template_data = [
                    'title' => _('Firewall'),
                    'description' => _('A firewall plugin that implements an iptables ruleset'),
                    'author' => _('zbchristian'),
                    'uri' => 'https://github.com/RaspAP/raspap-insiders',
                    'icon' => 'fas fa-fire-alt',
                    'serviceStatus' => $serviceStatus,
                    'serviceName' => 'firewall',
                    'ap_device' => $ap_device,
                    'str_clients' => $str_clients,
                    'fw_conf' => $fw_conf,
                    'vpn_ips' => $this->getVPN_IPs(),
                    'action' => 'plugin__'.$this->getName(),
                    'pluginName' => $this->getName()
                ];
                echo $this->renderTemplate($this->templateMain, compact(
                    "status",
                    "__template_data"
                ));
                return true;
            }
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
     * Applies the rules of firewall.conf with the root helper. The helper
     * checks each value and makes the rules from a fixed rule set.
     *
     * @param  array $output the output lines of the helper
     * @return boolean
     */
    protected function configureFirewall(&$output = [])
    {
        $output = [];
        exec('sudo '.escapeshellarg($this->firewallHelper).' apply 2>&1', $output, $rc);
        return $rc === 0;
    }

    /**
     *
     * @param array $conf
     * @return string $ret
     */
    protected function WriteFirewallConf($conf)
    {
        $ret = false;
        if (is_array($conf) ) {
            $ret = write_php_ini($conf, $this->firewallConfig);
        }
        return $ret;
    }

    /**
     *
     * @return array $conf
     */
    protected function ReadFirewallConf()
    {
        $conf = array();
        if (file_exists($this->firewallConfig) ) {
            $conf = parse_ini_file($this->firewallConfig);
        }
        if ( !isset($conf["firewall-enable"]) ) {
            $conf["firewall-enable"] = false;
            $conf["ssh-enable"] = false;
            $conf["http-enable"] = false;
            $conf["excl-devices"] = "";
            $conf["excluded-ips"] = "";
            $conf["ap-device"] = "";
            $conf["restricted-ips"] = "";
        }
        $links = (string)shell_exec('ip -o link show 2>/dev/null');
        $conf["openvpn-enable"] = preg_match('/^\d+: tun\d+[:@]/m', $links) === 1;
        $conf["wireguard-enable"] = preg_match('/^\d+: wg\d+[:@]/m', $links) === 1;
        return $conf;
    }

    /**
     *
     * @return string $ips
     */
    protected function getVPN_IPs()
    {
        // the root helper reads the WireGuard and OpenVPN configurations and
        // prints only the server hosts
        $ips = [];
        exec('sudo '.escapeshellarg($this->firewallHelper).' vpn-hosts 2>/dev/null', $hosts);
        foreach ($hosts as $host) {
            $ip = filter_var($host, FILTER_VALIDATE_IP) ? $host : gethostbyname($host);
            if (filter_var($ip, FILTER_VALIDATE_IP) && !in_array($ip, $ips, true)) {
                $ips[] = $ip;
            }
        }
        return implode(' ', $ips);
    }

    /**
     *
     * @return array $fw_conf
     */
    protected function getFirewallConfiguration()
    {
        $wifi = new WiFiManager(); 
        $scanner = new DeviceScanner();
        $fw_conf = $this->ReadFirewallConf();

        $wifi->getWifiInterface();
        $ap_device = $_SESSION['ap_interface'];
        $devices = $scanner->listDevices();
        $str_devices = "";
        foreach( $devices as $dev ) {
            if (!$dev["isAP"] ) {
                if (!empty($str_devices) ) {
                    $str_devices .= ", ";
                }
                $str_devices .= $dev["name"];
            }
        }
        $fw_conf["ap-device"] = $ap_device;
        $fw_conf["client-list"] = $str_devices;
        return $fw_conf;
    }

    /**
     *
     */
    protected function updateFirewall()
    {
        $fw_conf = $this->getFirewallConfiguration();
        if ( isset($fw_conf["firewall-enable"]) ) {
            $this->WriteFirewallConf($fw_conf);
            $this->configureFirewall();
        }
        return;
    }

    // Returns an abbreviated class name
    public static function getName(): string
    {
        return basename(str_replace('\\', '/', static::class));
    }

}

