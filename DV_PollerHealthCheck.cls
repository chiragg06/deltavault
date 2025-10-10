public with sharing class DV_PollerHealthCheck implements Schedulable, Queueable {

    // Schedulable entrypoint
    public void execute(SchedulableContext sc) {
        System.enqueueJob(this);
    }

    // Queueable logic: verify snapshots have been produced in the last hour
    public void execute(QueueableContext qc) {
        Datetime cutoff = System.now().addHours(-1);
        Integer countRecent = [SELECT COUNT() FROM OmniSnapshot__c WHERE ModifiedAt__c >= :cutoff];

        if (countRecent == 0) {
            // Minimal, safe signal: platform events/email/etc. can be added later.
            System.debug(LoggingLevel.WARN, 'DV_PollerHealthCheck: No snapshots in the last 60 minutes.');
        } else {
            System.debug('DV_PollerHealthCheck OK: ' + countRecent + ' snapshots in last hour.');
        }
    }
}
