public with sharing class DV_AdminApi {

    @AuraEnabled
    public static void runPollerNow(Integer lookbackMinutes) {
        DV_Poller.runNow(lookbackMinutes);
    }

    @AuraEnabled
    public static String startScheduler(Integer everyMinutes) {
        if (everyMinutes == null || everyMinutes < 1)  everyMinutes = 10;
        if (everyMinutes > 60)                         everyMinutes = 60;
        
        stopScheduler();
        
        // Build CRON expression for every N minutes
        // Format: Seconds Minutes Hours Day Month Weekday Year
        // Example: 0 0,10,20,30,40,50 * * * ? (every 10 minutes)
        
        List<String> mins = new List<String>();
        for (Integer m = 0; m < 60; m += everyMinutes) {
            mins.add(String.valueOf(m));
        }
        
        // CRON: second minute hour day month weekday
        String cron = '0 ' + String.join(mins, ',') + ' * * * ?';
        
        System.debug('Starting scheduler with CRON: ' + cron);
        
        return System.schedule('DeltaVault Poller', cron, new DV_Poller());
    }

    @AuraEnabled
    public static void stopScheduler() {
        for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = 'DeltaVault Poller']) {
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