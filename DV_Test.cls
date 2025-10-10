@IsTest
private class DV_Test {
    @IsTest static void utilDiff() {
        Map<String,Object> m1 = new Map<String,Object>{'Name'=>'A','Version__c'=>'1'};
        Map<String,Object> m2 = new Map<String,Object>{'Name'=>'A','Version__c'=>'2','IsActive__c'=>true};
        String diff = DV_AINotesUtil.unifiedDiff(JSON.serializePretty(m1), JSON.serializePretty(m2));
        System.assert(diff.contains('--- OLD'));
        System.assert(diff.contains('+++ NEW'));
        System.assert(diff.contains('+   "IsActive__c": true'));
    }
}
