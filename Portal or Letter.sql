USE P_Clarity_Report;
GO
DROP TABLE IF EXISTS #DICohort;
DROP TABLE IF EXISTS #DICohortwithFlags;
DROP TABLE IF EXISTS #RankEncounters;

/**************************************************************************************************************************
Identify Patients who have SDE PP#4944 completed.  This smartdata element corresponds to the 'Type of Respondent' question.
The SDE must have been last created/updated before 30/9/2023.
**************************************************************************************************************************/

SELECT DISTINCT 
       pat.PAT_NAME "Patient Name"
     , pat.PAT_ID
     , value.HLV_ID "Q1 HLV ID"
     , CAST(entity.CUR_VALUE_DATETIME AS DATE) "Last Updated"
     , CASE
           WHEN entity.CUR_VALUE_USER_ID = 'MyChartG'
           THEN 'MyChart'
           ELSE 'Clinician'
       END AS "Q1 Most Recently Entered Via"
     , value.SMRTDTA_ELEM_VALUE "Q1 Answer"
INTO #DICohort
FROM SMRTDTA_ELEM_DATA entity
     LEFT JOIN SMRTDTA_ELEM_VALUE value ON entity.HLV_ID = value.HLV_ID
     LEFT JOIN CLARITY_CONCEPT concept ON entity.ELEMENT_ID = concept.CONCEPT_ID
     LEFT JOIN PATIENT pat ON entity.PAT_LINK_ID = pat.PAT_ID
     LEFT JOIN PATIENT_4 pat4 ON pat.PAT_ID = pat4.PAT_ID -- Living status

WHERE entity.CONTEXT_NAME = 'PATIENT'
      AND entity.ELEMENT_ID IN('PP#4944')
     AND entity.CUR_VALUE_DATETIME < '2023-09-30'
     AND pat4.PAT_LIVING_STAT_C <> '2';  -- Is not deceased
--SELECT *
--FROM #DICohort;

/***************************************************
Determine if Letter or Portal
***************************************************/

SELECT pat.PAT_ID
     , pat.PAT_NAME
     , CAST(pat.BIRTH_DATE AS DATE) "DOB"
     , patfact.AGE_YEARS "Patient Age"
	 , patmyc.MYCHART_STATUS_C
     , patmycstat.NAME "Patient Portal Status"
     , CAST(mycpataccount.LAST_LOGIN_TIME AS DATE) "Last Patient Login"
     , mycpat.PAT_NAME "Proxy Name"
     , proxy.PROXY_WPR_ID "Proxy WPR"
     , proxy.PROXY_STATUS_C
     , mcstatus.NAME "Proxy Status"
     , CAST(mycpat.LAST_LOGIN_TIME AS DATE) "Last Proxy Login"
FROM PATIENT pat
     LEFT JOIN V_PAT_FACT patfact ON pat.PAT_ID = patfact.PAT_ID

     -- PROXY ACCOUNT DETAILS
     LEFT JOIN PAT_MYC_PRXY_ACSS proxy ON pat.PAT_ID = proxy.PAT_ID
     LEFT JOIN MYC_PATIENT mycpat ON proxy.PROXY_WPR_ID = mycpat.MYPT_ID
     LEFT JOIN ZC_MYCHART_STATUS mcstatus ON proxy.PROXY_STATUS_C = mcstatus.MYCHART_STATUS_C

     -- PATIENT ACCOUNT DETAILS
     LEFT JOIN PATIENT_MYC patmyc ON pat.PAT_ID = patmyc.PAT_ID
     LEFT JOIN ZC_MYCHART_STATUS patmycstat ON patmyc.MYCHART_STATUS_C = patmycstat.MYCHART_STATUS_C
     LEFT JOIN MYC_PATIENT mycpataccount ON patmyc.MYPT_ID = mycpataccount.MYPT_ID
WHERE pat.PAT_ID IN
(
    SELECT di.PAT_ID
    FROM #DICohort di
)
      AND (
	  
	  
	  (patfact.AGE_YEARS > 17
           AND patmyc.MYCHART_STATUS_C = '1'
         AND mycpataccount.LAST_LOGIN_TIME > '2023-05-23')
        OR (proxy.PROXY_WPR_ID <> '' AND mycpat.LAST_LOGIN_TIME > '2023-05-23' AND proxy.PROXY_STATUS_C <> '2')
		
		
		) --CHECK WITH NGHIEM! 
--AND pat.PAT_NAME LIKE '%Salaeh%'		
ORDER BY pat.PAT_NAME;