public with sharing class DV_SnapshotRetentionJob
    implements Schedulable, Database.Batchable<SObject>, Database.Stateful {

    private static Integer KEEP_DEFAULT = 200;
    private Integer keepPerComponent;

    public DV_SnapshotRetentionJob() { this.keepPerComponent = KEEP_DEFAULT; }
    public DV_SnapshotRetentionJob(Integer keepLimit) {
        this.keepPerComponent = (keepLimit == null || keepLimit < 20) ? KEEP_DEFAULT : keepLimit;
    }
    public static void setKeepLimit(Integer k) {
        KEEP_DEFAULT = (k == null || k < 20) ? 200 : k;
    }

    // Nightly schedule entry
    public void execute(SchedulableContext sc) {
        Database.executeBatch(new DV_SnapshotRetentionJob(KEEP_DEFAULT), 150);
    }

    // Manual one-off run helper (enqueue from DV_AdminApi)
    public class RunOnceQueue implements Queueable {
        public void execute(QueueableContext qc) {
            Database.executeBatch(new DV_SnapshotRetentionJob(KEEP_DEFAULT), 150);
        }
    }

    // Batchable<SObject>
    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator('SELECT Id FROM OmniComponent__c');
    }

    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        for (SObject rec : scope) {
            Id cid = (Id)rec.get('Id');

            // Keep newest N; delete older ones.
            // SOQL order: ORDER BY ... LIMIT ... OFFSET ...
            List<OmniSnapshot__c> toDelete = [
                SELECT Id
                FROM OmniSnapshot__c
                WHERE OmniComponent__c = :cid
                ORDER BY ModifiedAt__c DESC, Id DESC
                LIMIT 1000 OFFSET :keepPerComponent
            ];
            if (!toDelete.isEmpty()) {
                delete toDelete;
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug('DV_SnapshotRetentionJob finished; keep per component = ' + keepPerComponent);
    }
}
