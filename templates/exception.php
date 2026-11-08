<?php
// Hardened fork: all users see the reference of the log line. Only a
// logged-in admin user sees the message and the trace (escaped).
$h = function ($s) { return htmlspecialchars((string)$s, ENT_QUOTES, 'UTF-8'); };
?>
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title><?php echo _("RaspAP Exception"); ?></title>
    <link href="dist/bootstrap/css/bootstrap.css" rel="stylesheet">
    <link href="dist/sb-admin-2/css/sb-admin-2.min.css" rel="stylesheet">
    <link rel="shortcut icon" type="image/png" href="app/icons/favicon.png?ver=2.0">
  </head>
  <body id="page-top">
    <div id="wrapper">
      <div id="content-wrapper" class="d-flex flex-column">
        <div id="content">
          <div class="row">
            <div class="col-lg-12">
              <p class="text-light bg-danger ps-3 p-1"><?php echo _("RaspAP Exception"); ?></p>
            </div>
            <div class="col-lg-12 ms-3">
              <h3 class="mt-2"><?php echo _("An exception occurred"); ?></h3>
              <p><?php echo _("Reference"); ?>: <code><?php echo $h($reference); ?></code></p>
<?php if ($details) : ?>
              <h5><?php echo $h($message); ?></h5>
              <p><?php echo $h($file); ?>:<?php echo $h($line); ?></p>
              <h5>Stack trace:</h5>
              <pre><?php echo $h($trace); ?></pre>
<?php else : ?>
              <p><?php echo _("The administrator can find the details in the error log."); ?></p>
<?php endif; ?>
            </div>
          </div>
        </div>
      </div>
    </div>
  </body>
</html>
