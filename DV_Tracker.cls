public with sharing class DV_Tracker {

    @testVisible private static Boolean skip = false;

    private class Ev {
        String fullName; DV_Constants.CompType compType;
        Map<String,Object> afterM; String sourceTag;
        Ev(String fn, DV_Constants.CompType t, Map<String,Object> m, String src){
            fullName=fn; compType=t; afterM=m; sourceTag=src;
        }
    }

    // Not used when triggers are disabled. Kept for parity/testing.
    public static void handle(List<SObject> news, Map<Id,SObject> olds) {
        if (skip || news == null || news.isEmpty()) return;
        // Intentionally not implemented for the triggerless deployment.
    }
}
