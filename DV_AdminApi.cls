public with sharing class DV_AdminApi {

    @AuraEnabled
    public static void runPollerNow(Integer lookbackMinutes) {
        DV_Poller.runNow(lookbackMinutes);
    }

    @AuraEnabled
    public static String startScheduler(Integer everyMinutes) {
        if (everyMinutes == null || everyMinutes < 1)  everyMinutes = 30;
        
        stopScheduler();
        
        // Salesforce CRON limitations:
        // - Can only schedule at ONE specific minute per hour
        // - Cannot use comma-separated values like "0,30"
        // - For "every 30 minutes", we need to schedule multiple jobs
        
        String jobName = 'DeltaVault Poller';
        
        if (everyMinutes <= 30) {
            // For 30 minutes or less, schedule multiple jobs at different minutes
            Integer jobCount = 60 / everyMinutes;
            
            for (Integer i = 0; i < jobCount; i++) {
                Integer minute = i * everyMinutes;
                
                // CRON format: Seconds Minutes Hours Day Month Weekday
                // Run at specific minute every hour
                String cron = '0 ' + minute + ' * * * ?';
                String uniqueJobName = jobName + (i > 0 ? ' ' + i : '');
                
                System.debug('Scheduling: ' + uniqueJobName + ' with CRON: ' + cron);
                System.schedule(uniqueJobName, cron, new DV_Poller());
            }
            
            return jobCount + ' jobs scheduled (every ' + everyMinutes + ' minutes)';
        } else {
            // For longer intervals, just schedule once per hour
            String cron = '0 0 * * * ?'; // Every hour at minute 0
            System.debug('Scheduling with CRON: ' + cron);
            return System.schedule(jobName, cron, new DV_Poller());
        }
    }

    @AuraEnabled
    public static void stopScheduler() {
        // Stop all DeltaVault Poller jobs (including numbered variants)
        for (CronTrigger ct : [
            SELECT Id FROM CronTrigger 
            WHERE CronJobDetail.Name LIKE 'DeltaVault Poller%'
        ]) {
            System.abortJob(ct.Id);
        }
    }

    // Track & Ingest all versions under one logical component (BaseName)
    @AuraEnabled
    public static void trackAndIngestBase(String family, String baseName) {
        DV_Poller.ingestBaseAllVersions(family, baseName);
    }

    // Bulk baseline per family
    @AuraEnabled
    public static void ingestAll(String family){
        DV_Poller.ingestAllByFamily(family);
    }
}