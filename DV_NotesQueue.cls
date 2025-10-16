public with sharing class DV_NotesQueue implements Queueable, Database.AllowsCallouts {
    private List<Id> snapshotIds;
    public DV_NotesQueue(List<Id> ids) { this.snapshotIds = ids; }

    public void execute(QueueableContext qc) {
        if (snapshotIds == null || snapshotIds.isEmpty()) return;
        List<OmniSnapshot__c> snaps = [
            SELECT Id, RawJSON__c, DiffToPrev__c, ElementChangesSummary__c, OmniComponent__r.FullName__c
            FROM OmniSnapshot__c WHERE Id IN :snapshotIds
        ];
        List<OmniSnapshot__c> upd = new List<OmniSnapshot__c>();
        for (OmniSnapshot__c s : snaps) {
            // CRITICAL: Pass ElementChangesSummary__c to aiNotes
            String html = DV_AINotesUtil.aiNotes(
                s.OmniComponent__r.FullName__c, 
                s.DiffToPrev__c, 
                s.RawJSON__c,
                s.ElementChangesSummary__c
            );
            upd.add(new OmniSnapshot__c(Id=s.Id, AI_Notes_Markdown__c=html));
        }
        if (!upd.isEmpty()) update upd;
    }
}