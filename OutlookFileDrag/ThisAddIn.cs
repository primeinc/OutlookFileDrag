using System;
using System.Reflection;
using log4net;

namespace OutlookFileDrag
{
    public partial class ThisAddIn
    {
        private static ILog log = LogManager.GetLogger(System.Reflection.MethodBase.GetCurrentMethod().DeclaringType);
        private System.Threading.Timer cleanupTimer;
        private DragDropHook hook;

        //Defaults applied when the App.config values are missing/malformed (matches the shipped
        //App.config CleanupTimerInterval / TempFileExpiration = 60), so a bad config no longer
        //aborts startup or silently disables interception.
        private const int DefaultCleanupTimerIntervalMinutes = 60;
        private const int DefaultTempFileExpirationMinutes = 60;

        private void ThisAddIn_Startup(object sender, System.EventArgs e)
        {
            //Configure logging
            log4net.Config.XmlConfigurator.Configure();

            try
            {                
                log.Info("Add-in startup");

                //Log version, OS version, Outlook version, and language
                log.InfoFormat("Version: {0}", Assembly.GetExecutingAssembly().GetName().Version.ToString());
                log.InfoFormat("OS: {0} {1}", Environment.OSVersion, Environment.Is64BitOperatingSystem ? "x64" : "x86");
                log.InfoFormat("Outlook version: {0} {1}", this.Application.Version, Environment.Is64BitProcess ? "x64" : "x86");
                log.InfoFormat("Language: {0}", Application.LanguageSettings.get_LanguageID(Microsoft.Office.Core.MsoAppLanguageID.msoLanguageIDUI));

                //Set up exception handlers
                System.Windows.Forms.Application.ThreadException += Application_ThreadException;
                AppDomain.CurrentDomain.UnhandledException += CurrentDomain_UnhandledException;

                //Start cleanup timer
                //Require a positive interval: a non-positive value would make the Timer period invalid
                //(negative -> ArgumentOutOfRangeException aborts startup; 0 -> fires only once).
                int cleanupTimerInterval;
                if (!int.TryParse(System.Configuration.ConfigurationManager.AppSettings["CleanupTimerInterval"], out cleanupTimerInterval) || cleanupTimerInterval <= 0)
                    cleanupTimerInterval = DefaultCleanupTimerIntervalMinutes;
                log.InfoFormat("Starting cleanup timer -- run every {0} minutes", cleanupTimerInterval);
                cleanupTimer = new System.Threading.Timer(CleanupTimer_Callback, null, 0, cleanupTimerInterval * 60 * 1000);

                //Start hook (unless disabled via the kill-switch -- lets IT neuter interception
                //fleet-wide without uninstalling when a future Office build breaks it)
                if (HookEnabled())
                {
                    hook = new DragDropHook();
                    hook.Start();

                    //Outlook no longer reliably raises Shutdown, so restore the import slots on
                    //process exit to avoid leaving a dangling redirect if the add-in is unloaded.
                    AppDomain.CurrentDomain.ProcessExit += CurrentDomain_ProcessExit;
                }
                else
                {
                    log.Info("DoDragDrop interception disabled (EnableHook=false) -- not hooking");
                }
            }
            catch (Exception ex)
            {
                log.Fatal("Fatal error", ex);
                if (hook != null)
                    hook.Stop();
            }
        }

        //Kill-switch: a registry override (HKLM or HKCU \Software\OutlookFileDrag\EnableHook = 0)
        //takes precedence so it can be pushed via policy; otherwise the App.config value is used.
        //Defaults to enabled when nothing is set.
        private static bool HookEnabled()
        {
            foreach (var root in new[] { Microsoft.Win32.Registry.LocalMachine, Microsoft.Win32.Registry.CurrentUser })
            {
                try
                {
                    using (var key = root.OpenSubKey(@"Software\OutlookFileDrag"))
                    {
                        object val = key?.GetValue("EnableHook");
                        if (val != null)
                            return Convert.ToInt32(val) != 0;
                    }
                }
                catch (Exception ex)
                {
                    log.WarnFormat("Could not read EnableHook registry override: {0}", ex.Message);
                }
            }

            bool enabled;
            if (bool.TryParse(System.Configuration.ConfigurationManager.AppSettings["EnableHook"], out enabled))
                return enabled;
            return true;
        }

        private void CurrentDomain_ProcessExit(object sender, EventArgs e)
        {
            try
            {
                if (hook != null)
                    hook.Stop();
            }
            catch (Exception ex)
            {
                log.WarnFormat("Error during process-exit hook teardown: {0}", ex.Message);
            }
        }

        private void CurrentDomain_UnhandledException(object sender, UnhandledExceptionEventArgs e)
        {
            log.Fatal("Appdomain exception", (Exception)e.ExceptionObject);
        }

        private void Application_ThreadException(object sender, System.Threading.ThreadExceptionEventArgs e)
        {
            log.Fatal("Application thread exception", e.Exception);
        }

        private void CleanupTimer_Callback(object state)
        {
            try
            {
                //Require a positive expiration: 0/negative would delete temp folders created "before
                //now" -- including the one backing an in-progress drag.
                int tempFileExpiration;
                if (!int.TryParse(System.Configuration.ConfigurationManager.AppSettings["TempFileExpiration"], out tempFileExpiration) || tempFileExpiration <= 0)
                    tempFileExpiration = DefaultTempFileExpirationMinutes;
                log.InfoFormat("Cleaning up temp files older than {0} minutes", tempFileExpiration);
                FileUtility.CleanupTempPath(tempFileExpiration);
            }
            catch (Exception ex)
            {
                log.Error("Error cleaning up temp files", ex);
            }
        }

        private void ThisAddIn_Shutdown(object sender, System.EventArgs e)
        {
            // Note: Outlook no longer raises this event. If you have code that 
            //    must run when Outlook shuts down, see http://go.microsoft.com/fwlink/?LinkId=506785

            try
            {
                log.Info("Add-in shutdown");
                if (hook != null)
                    hook.Stop();
            }
            catch (Exception ex)
            {
                log.Fatal("Fatal error", ex);
            }
        }

        #region VSTO generated code

        /// <summary>
        /// Required method for Designer support - do not modify
        /// the contents of this method with the code editor.
        /// </summary>
        private void InternalStartup()
        {
            this.Startup += new System.EventHandler(ThisAddIn_Startup);
            this.Shutdown += new System.EventHandler(ThisAddIn_Shutdown);
        }

        #endregion
    }
}
