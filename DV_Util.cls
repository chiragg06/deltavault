public with sharing class DV_Util {

    // ---- Type mapping -------------------------------------------------------
    public static DV_Constants.CompType mapType(SObject rec) {
        String api = rec.getSObjectType().getDescribe().getName();
        if (api == 'OmniUiCard')             return DV_Constants.CompType.Flexcard;
        if (api == 'OmniProcess')            return DV_Constants.CompType.OmniProcess;
        if (api == 'OmniProcessElement')     return DV_Constants.CompType.OmniProcessElement;
        if (api == 'OmniProcessCompilation') return DV_Constants.CompType.OmniProcessCompilation;
        if (api == 'OmniDataTransform')      return DV_Constants.CompType.DataMapper;
        if (api == 'OmniDataTransformItem')  return DV_Constants.CompType.DataMapperItem;
        return DV_Constants.CompType.Unknown;
    }

    // ---- Full name (human) --------------------------------------------------
    public static String deriveFullName(SObject rec, DV_Constants.CompType t) {
        Map<String, Schema.SObjectField> f = rec.getSObjectType().getDescribe().fields.getMap();

        String base = pickFirst(rec, f, new List<String>{
            'UniqueName','DeveloperName','ApiName','OmniUiCardKey','OmniProcessKey','Name'
        });
        if (String.isBlank(base)) base = String.valueOf(rec.get('Id'));

        String type  = f.containsKey('Type')    && rec.get('Type')    != null ? String.valueOf(rec.get('Type'))    : null;
        String sub   = f.containsKey('SubType') && rec.get('SubType') != null ? String.valueOf(rec.get('SubType')) : null;

        String typeSub = null;
        if (!String.isBlank(type)) typeSub = type;
        if (!String.isBlank(sub))  typeSub = (typeSub==null? '' : typeSub + '/') + sub;

        Decimal ver = sniffVersion(rec);
        String name = base;
        if (!String.isBlank(typeSub)) name += ' • ' + typeSub;
        if (t == DV_Constants.CompType.OmniProcess && ver != null) name += ' v' + String.valueOf(ver);
        return name;
    }
    private static String pickFirst(SObject rec, Map<String, Schema.SObjectField> f, List<String> keys) {
        for (String k : keys) if (f.containsKey(k) && rec.get(k) != null) return String.valueOf(rec.get(k));
        return null;
    }

    // Strip trailing " vN" or " vN.M"
    public static String stripVersion(String full) {
        if (String.isBlank(full)) return '';
        return full.trim().replaceAll('\\s+v[0-9]+(\\.[0-9]+)?$','');
    }

    // ---- JSON helpers -------------------------------------------------------
    public static String normalizeJson(String maybeJson, Integer max) {
        if (String.isBlank(maybeJson)) return null;
        try {
            Object u = JSON.deserializeUntyped(maybeJson);
            Object sorted = sortJson(u);
            String pretty = JSON.serializePretty(sorted);
            if (max != null && pretty.length() > max) return pretty.substring(0, max) + '\n... [truncated]';
            return pretty;
        } catch (Exception ex) {
            return (max != null && maybeJson.length() > max)
                ? maybeJson.substring(0, max) + '\n... [truncated]'
                : maybeJson;
        }
    }
    private static Object sortJson(Object val) {
        if (val instanceof Map<String,Object>) {
            Map<String,Object> m = (Map<String,Object>)val;
            List<String> ks = new List<String>(m.keySet()); ks.sort();
            Map<String,Object> out = new Map<String,Object>();
            for (String k : ks) out.put(k, sortJson(m.get(k)));
            return out;
        } else if (val instanceof List<Object>) {
            List<Object> a = (List<Object>)val, out = new List<Object>();
            for (Object o : a) out.add(sortJson(o));
            return out;
        }
        return val;
    }

    // ---- Project interesting fields ----------------------------------------
    public static Map<String,Object> projectInteresting(SObject rec) {
        String api = rec.getSObjectType().getDescribe().getName();
        Map<String, Schema.SObjectField> f = rec.getSObjectType().getDescribe().fields.getMap();
        Map<String,Object> m = new Map<String,Object>();

        putIfPresent(rec,f,m,'Name'); putIfPresent(rec,f,m,'UniqueName'); putIfPresent(rec,f,m,'DeveloperName');
        putIfPresent(rec,f,m,'ApiName'); putIfPresent(rec,f,m,'OmniUiCardKey'); putIfPresent(rec,f,m,'OmniProcessKey');
        putIfPresent(rec,f,m,'OmniUiCardType'); putIfPresent(rec,f,m,'OmniProcessType');
        putIfPresent(rec,f,m,'Type'); putIfPresent(rec,f,m,'SubType');
        putIfPresent(rec,f,m,'IsActive'); putIfPresent(rec,f,m,'Active');
        putIfPresent(rec,f,m,'VersionNumber'); putIfPresent(rec,f,m,'OmniScriptVersionNumber'); putIfPresent(rec,f,m,'OmniProcessVersionNumber');
        putIfPresent(rec,f,m,'Language');

        if (api == 'OmniUiCard') {
            normIfPresent(rec,f,m,'PropertySetConfig',130000);
            normIfPresent(rec,f,m,'DataSourceConfig',130000);
            normIfPresent(rec,f,m,'StylingConfiguration',130000);
            normIfPresent(rec,f,m,'SampleDataSourceResponse',60000);
        } else if (api == 'OmniProcess') {
            normIfPresent(rec,f,m,'IntegrationProcedureInput',60000);
            normIfPresent(rec,f,m,'IntegrationProcedureOutput',60000);
            normIfPresent(rec,f,m,'CustomJavaScript',60000);
            normIfPresent(rec,f,m,'CustomHtmlTemplates',60000);
        } else if (api == 'OmniProcessElement') {
            putIfPresent(rec,f,m,'ParentElementName'); putIfPresent(rec,f,m,'Type');
            putIfPresent(rec,f,m,'SequenceNumber'); putIfPresent(rec,f,m,'Level');
            normIfPresent(rec,f,m,'PropertySetConfig',60000);
        } else if (api == 'OmniDataTransform') {
            putIfPresent(rec,f,m,'Type'); putIfPresent(rec,f,m,'GlobalKey');
            normIfPresent(rec,f,m,'ExpectedInputJson',90000);
            normIfPresent(rec,f,m,'ExpectedOutputJson',90000);
        } else if (api == 'OmniDataTransformItem') {
            putIfPresent(rec,f,m,'FormulaExpression'); putIfPresent(rec,f,m,'FormulaResultPath');
            normIfPresent(rec,f,m,'DefaultValue',20000);
            normIfPresent(rec,f,m,'InputFieldName',20000);
            putIfPresent(rec,f,m,'OutputObjectName'); putIfPresent(rec,f,m,'OutputFieldName');
            putIfPresent(rec,f,m,'InputObjectName');  putIfPresent(rec,f,m,'InputFieldName');
            putIfPresent(rec,f,m,'LookupObjectName'); putIfPresent(rec,f,m,'LookupByFieldName'); putIfPresent(rec,f,m,'LookupReturnedFieldName');
        }
        return m;
    }

    public static Decimal sniffVersion(SObject rec) {
        if (rec == null) return null;
        Map<String, Schema.SObjectField> f = rec.getSObjectType().getDescribe().fields.getMap();
        Object v = null;
        if (f.containsKey('VersionNumber')) v = rec.get('VersionNumber');
        else if (f.containsKey('OmniScriptVersionNumber')) v = rec.get('OmniScriptVersionNumber');
        else if (f.containsKey('OmniProcessVersionNumber')) v = rec.get('OmniProcessVersionNumber');
        return toDecimalSafe(v);
    }
    public static Decimal sniffVersion(Map<String,Object> m) {
        if (m == null) return null;
        Object v = null;
        if (m.containsKey('VersionNumber')) v = m.get('VersionNumber');
        else if (m.containsKey('OmniScriptVersionNumber')) v = m.get('OmniScriptVersionNumber');
        else if (m.containsKey('OmniProcessVersionNumber')) v = m.get('OmniProcessVersionNumber');
        return toDecimalSafe(v);
    }
    private static Decimal toDecimalSafe(Object v) {
        if (v == null) return null;
        try { return (v instanceof Decimal) ? (Decimal)v : Decimal.valueOf(String.valueOf(v)); }
        catch (Exception e) { return null; }
    }

    private static void putIfPresent(SObject rec, Map<String,Schema.SObjectField> f, Map<String,Object> out, String field){
        if (f.containsKey(field)) out.put(field, rec.get(field));
    }
    private static void normIfPresent(SObject rec, Map<String,Schema.SObjectField> f, Map<String,Object> out, String field, Integer max){
        if (f.containsKey(field) && rec.get(field) != null)
            out.put(field, normalizeJson(String.valueOf(rec.get(field)), max));
    }

    // ---- Describe-aware field list -----------------------------------------
    public static String fieldListFor(String apiName) {
        Schema.SObjectType t = Schema.getGlobalDescribe().get(apiName);
        if (t == null) return 'Id, LastModifiedDate';
        Map<String, Schema.SObjectField> fmap = t.getDescribe().fields.getMap();

        List<String> order = new List<String>();
        if (fmap.containsKey('Id'))               order.add('Id');
        if (fmap.containsKey('LastModifiedDate')) order.add('LastModifiedDate');

        List<String> wanted = new List<String>{
            'Name','UniqueName','DeveloperName','ApiName',
            'OmniUiCardKey','OmniProcessKey','OmniUiCardType','OmniProcessType',
            'Type','SubType','IsActive','Active',
            'VersionNumber','OmniScriptVersionNumber','OmniProcessVersionNumber',
            'DataSourceConfig','StylingConfiguration','PropertySetConfig','SampleDataSourceResponse',
            'IntegrationProcedureInput','IntegrationProcedureOutput','CustomJavaScript','CustomHtmlTemplates','Language',
            'ExpectedInputJson','ExpectedOutputJson','InputType','OutputType','GlobalKey',
            'FormulaExpression','FormulaResultPath','DefaultValue','InputFieldName','ParentElementName','SequenceNumber','Level',
            'OmniProcessId','OmniDataTransformationId'
        };
        for (String f : wanted) if (fmap.containsKey(f) && order.indexOf(f) < 0) order.add(f);
        return String.join(order, ',');
    }
}
