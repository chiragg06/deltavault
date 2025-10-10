public with sharing class DV_Constants {
    public enum CompType {
        Flexcard, OmniProcess, OmniProcessElement, OmniProcessCompilation,
        DataMapper, DataMapperItem, Unknown
    }

    public class FieldsBag {
        // OmniComponent__c
        public final String OC_FullName   = 'FullName__c';
        public final String OC_Type       = 'OmniType__c';
        public final String OC_SubType    = 'SubType__c';
        public final String OC_Active     = 'IsActive__c';
        public final String OC_LastSeenAt = 'LastSeenModified__c';
        public final String OC_Tracked    = 'Tracked__c';

        // OmniSnapshot__c
        public final String OS_Component  = 'OmniComponent__c';
        public final String OS_OccurredAt = 'ModifiedAt__c';
        public final String OS_ActorName  = 'ActorName__c';
        public final String OS_ChangeType = 'ChangeType__c';
        public final String OS_Raw        = 'RawJSON__c';
        public final String OS_Diff       = 'DiffToPrev__c';
        public final String OS_Notes      = 'AI_Notes_Markdown__c';
        public final String OS_Source     = 'Source__c';
        public final String OS_Version    = 'Version__c';
    }
    public static final FieldsBag Field = new FieldsBag();
}
