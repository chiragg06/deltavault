public with sharing class DV_ComponentVersionService {

    /**
     * Returns a UI "logical name" that collapses multiple versions of the same OmniProcess/IP
     * into one bucket. We simply strip a trailing " v<digits[.digits]?>" if present.
     * Example: "MyFlow • OmniScript v3" -> "MyFlow • OmniScript"
     */
    public static String normalizeForUi(String fullName, String omniType) {
        if (String.isBlank(fullName)) return fullName;
        if (omniType == 'OmniProcess') {
            // Trim " v12" or " v12.3" at the end
            return fullName.replaceAll('\\s+v\\d+(?:\\.\\d+)?$','');
        }
        return fullName;
    }

    /**
     * Find all component ids that belong to the same UI "logical" process as the given component.
     * We compute the normalized name for the anchor component, then find other OmniComponent__c
     * whose normalized name matches.
     */
    public static Set<Id> resolveFamilyComponentIds(Id anchorComponentId) {
        if (anchorComponentId == null) return new Set<Id>();
        OmniComponent__c anchor = [
            SELECT Id, FullName__c, OmniType__c
            FROM OmniComponent__c WHERE Id = :anchorComponentId LIMIT 1
        ];
        String norm = normalizeForUi(anchor.FullName__c, anchor.OmniType__c);

        // Fetch candidates of same type, then filter in Apex using normalizer
        List<OmniComponent__c> sameType = [
            SELECT Id, FullName__c, OmniType__c
            FROM OmniComponent__c
            WHERE OmniType__c = :anchor.OmniType__c
        ];
        Set<Id> out = new Set<Id>();
        for (OmniComponent__c c : sameType) {
            if (normalizeForUi(c.FullName__c, c.OmniType__c) == norm) out.add(c.Id);
        }
        return out;
    }
}
