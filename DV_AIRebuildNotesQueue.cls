public with sharing class DV_AIRebuildNotesQueue implements Queueable, Database.AllowsCallouts {
    public void execute(QueueableContext qc) {
        List<OmniSnapshot__c> snaps = [
            SELECT Id, RawJSON__c, DiffToPrev__c, ElementChangesSummary__c, OmniComponent__r.FullName__c, AI_Notes_Markdown__c
            FROM OmniSnapshot__c
            ORDER BY ModifiedAt__c DESC, Id DESC
            LIMIT 500
        ];
        if (snaps.isEmpty()) return;

        List<OmniSnapshot__c> upd = new List<OmniSnapshot__c>();
        for (OmniSnapshot__c s : snaps) {
            if (!String.isBlank(s.AI_Notes_Markdown__c)) continue;
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