<?php

/**
 * Plugin Installer class
 *
 * @description Class to handle installation of user plugins
 * @author      Bill Zimmerman <billzimmerman@gmail.com>
 * @license     https://github.com/raspap/raspap-webgui/blob/master/LICENSE
 */

declare(strict_types=1);

namespace RaspAP\Plugins;

class PluginInstaller
{
    private static $instance = null;
    private string $pluginPath;
    private string $rootPath;
    private string $pluginsManifest;
    private string $helperScriptPath;

    public function __construct()
    {
        $this->pluginPath = 'plugins';
        $this->rootPath = dirname(__DIR__, 3);
        // the plugin list of the hardened fork. It is part of each release,
        // so an update does not change it from outside
        $this->pluginsManifest = '/config/plugins.json';
        $this->helperScriptPath = RASPI_CONFIG.'/plugins/plugin_helper.sh';
    }

    // Returns a single instance of PluginInstaller
    public static function getInstance(): PluginInstaller
    {
        if (self::$instance === null) {
            self::$instance = new PluginInstaller();
        }
        return self::$instance;
    }

    /**
     * Returns availble user plugin details from a manifest.json file
     *
     * @return array $plugins
     */
    public function getUserPlugins()
    {
        try {
            $manifestPath = $this->rootPath . $this->pluginsManifest;
            if (!file_exists($manifestPath)) {
                throw new \Exception("Manifest file not found at " . $manifestPath);
            }

            // decode manifest file contents
            $manifestContents = file_get_contents($manifestPath);
            $manifestData = json_decode($manifestContents, true);

            if (json_last_error() !== JSON_ERROR_NONE) {
                throw new \Exception("Error parsing manifest.json: " . json_last_error_msg());
            }

            // fetch installed plugins
            $installedPlugins = $this->getPlugins();
            $plugins = [];

            foreach ($manifestData as $pluginManifest) {
                $pluginEntries = [];

                foreach ($pluginManifest as $plugin) {
                    $installed = false;

                    if (!empty($plugin['namespace'])) {
                        foreach ($installedPlugins as $installedPlugin) {
                            if (strpos($installedPlugin['class'], $plugin['namespace']) !== false) {
                                $installed = true;
                                break;
                            }
                        }
                    }
                    $pluginEntries[] = [
                        'manifest' => $plugin,
                        'installed' => $installed
                    ];
                }
                $plugins[] = $pluginEntries;
            }
            return array_merge(...$plugins);
        } catch (\Exception $e) {
            error_log("An error occurred: " . $e->getMessage());
            throw $e; // re-throw to global ExceptionHandler
        }
    }

    /**
     * Returns an array of installed plugins in pluginPath
     *
     * @param string|null $path; optional path to search for plugins. Defaults to $this->pluginPath.
     * @return array $plugins
     */
    public function getPlugins(?string $path = null): array
    {
        $plugins = [];
        $pluginPath = $path ?? $this->pluginPath;

        if (file_exists($pluginPath)) {
            $directories = scandir($pluginPath);

            foreach ($directories as $directory) {
                if ($directory === '.' || $directory === '..') {
                    continue;
                }
                $pluginClass = "RaspAP\\Plugins\\$directory\\$directory";
                $pluginFile = "$pluginPath/$directory/$directory.php";

                if (file_exists($pluginFile)) {
                    if ($path === 'plugins-available') {
                        require_once $pluginFile;
                    }
                    if (class_exists($pluginClass)) {
                        $plugins[] = [
                            'class' => $pluginClass,
                            'installPath' => $pluginPath
                        ];
                    }
                }
            }
        }
        return $plugins;
    }

    /**
     * Installs a plugin of the plugin list. The browser sends only the name.
     *
     * Hardened fork: the root helper plugin_helper.sh does the complete
     * install. It reads the plugin from root-owned copies of the plugin list
     * and of the bundled plugins, checks the complete entry first, and
     * removes its changes when a step fails.
     *
     * @param string $name the name of the plugin in the plugin list
     * @return boolean
     * @throws \Exception
     */
    public function installPluginByName(string $name): bool
    {
        $entry = null;
        foreach ($this->getUserPlugins() as $plugin) {
            if (($plugin['manifest']['name'] ?? null) === $name) {
                $entry = $plugin['manifest'];
                break;
            }
        }
        if ($entry === null) {
            throw new \Exception('The plugin is not in the plugin list.');
        }
        if (!empty($entry['unavailable'])) {
            throw new \Exception('This plugin is not available in the hardened fork: ' . (string)$entry['unavailable']);
        }
        $proc = proc_open(
            ['sudo', $this->helperScriptPath, 'install', $name],
            [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
            $pipes
        );
        if (!is_resource($proc)) {
            throw new \Exception('Unable to start the plugin helper.');
        }
        stream_get_contents($pipes[1]);
        $error = trim((string)stream_get_contents($pipes[2]));
        fclose($pipes[1]);
        fclose($pipes[2]);
        $rc = proc_close($proc);
        if ($rc !== 0) {
            error_log('Plugin installation failed: ' . $error);
            throw new \Exception($error !== '' ? $error : 'The plugin helper failed (exit status ' . $rc . ').');
        }
        return true;
    }

    /**
     * Returns a list of available plugins formatted as an HTML table
     *
     * @param array $plugins
     * @return string $html
     */
    public function getHTMLPluginsTable(array $plugins): string
    {
        $html = '<table class="table table-striped table-hover">';
        $html .= '<thead><tr>';
        $html .= '<th scope="col">Name</th>';
        $html .= '<th scope="col">Version</th>';
        $html .= '<th scope="col">Description</th>';
        $html .= '<th scope="col"></th>';
        $html .= '</tr></thead><tbody>';

        foreach ($plugins as $plugin) {
            $manifestData = $plugin['manifest'] ?? [];
            $installed = $plugin['installed'] ?? false;
            $manifest = htmlspecialchars(json_encode($manifestData), ENT_QUOTES, 'UTF-8');
            $button = '';

            if ($installed === true) {
                $button = '<button type="button" class="btn btn-outline-primary btn-sm text-nowrap"
                    name="plugin-details" data-bs-toggle="modal" data-bs-target="#install-user-plugin"
                    data-plugin-manifest="' .$manifest. '" data-plugin-installed="' .$installed. '">' . _("Installed") .'</button>';
            } elseif (!empty($manifestData['unavailable'])) {
                // hardened fork: the plugin needs a root helper first
                $button = '<button type="button" class="btn btn-outline-secondary btn-sm text-nowrap" disabled
                    title="' . htmlspecialchars((string)$manifestData['unavailable'], ENT_QUOTES, 'UTF-8') . '">'
                    . _("Not available") .'</button>';
            } elseif (!RASPI_MONITOR_ENABLED) {
                $button = '<button type="button" class="btn btn-outline-primary btn-sm text-nowrap"
                    name="install-plugin" data-bs-toggle="modal" data-bs-target="#install-user-plugin"
                    data-plugin-manifest="' .$manifest. '">' . _("Details") .'</button>';
            }
    
            $icon = htmlspecialchars($manifestData['icon'] ?? '');
            $pluginDocs = htmlspecialchars($manifestData['plugin_docs'] ?? '');
            $nameText = htmlspecialchars($manifestData['name'] ?? 'Unknown Plugin');
            $name = '<i class="' .$icon. ' link-secondary me-2"></i><a href="'
                .$pluginDocs
                .'" target="_blank">'
                .$nameText. '</a>';
            $version = htmlspecialchars($manifestData['version'] ?? 'N/A');
            $description = htmlspecialchars($manifestData['description'] ?? 'No description available');

            $html .= '<tr><td>' .$name. '</td>';
            $html .= '<td>' .$version. '</td>';
            $html .= '<td>' .$description. '</td>';
            $html .= '<td>' .$button. '</td></tr>';
        }
        $html .= '</tbody></table>';
        return $html;
    }
}

