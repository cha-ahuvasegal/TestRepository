USE P_Clarity_Report;
GO
DROP TABLE IF EXISTS #DICohort;
DROP TABLE IF EXISTS #DICohortwithFlags;
DROP TABLE IF EXISTS #CommunicationMode;
DROP TABLE IF EXISTS #RankEncounters;

/**************************************************************************************************************************
Identify Patients who have SDE PP#4944 completed.  This smartdata element corresponds to the 'Type of Respondent' question.
The SDE must have been last created/updated before 30/9/2023.
**************************************************************************************************************************/

SELECT DISTINCT 
       pat.PAT_ID "Pat ID"
     , pat.PAT_NAME "Patient Name"
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
     LEFT JOIN VALID_PATIENT valid ON pat.PAT_ID = valid.PAT_ID
WHERE entity.CONTEXT_NAME = 'PATIENT'
      AND entity.ELEMENT_ID IN('PP#4944')
     AND entity.CUR_VALUE_DATETIME < '2023-09-30'
     AND pat4.PAT_LIVING_STAT_C <> '2'  -- Is not deceased
     AND valid.IS_VALID_PAT_YN = 'Y'; -- Is not a test patient;
SELECT *
FROM #DICohort;

/*****************************************************
Find High Risk FYI Flags and Concatenate Distinct List
*****************************************************/

SELECT DISTINCT 
       #DICohort.*
     , CASE
           WHEN EXISTS
(
    SELECT genflag.PATIENT_ID
    FROM PATIENT_FYI_FLAGS genflag
    WHERE genflag.ACTIVE_C = '1'
          AND genflag.PAT_FLAG_TYPE_C = '1'
          AND genflag.PATIENT_ID = #DICohort.[Pat ID]
)
           THEN 'Yes'
           ELSE ''
       END AS "Gen Flag"
     , CASE
           WHEN hrfyi.[High Risk Flag] <> ''
           THEN hrfyi.[High Risk Flag]
           ELSE ''
       END AS "High Risk Flag"
INTO #DICohortwithFlags
FROM #DICohort
     LEFT JOIN --Coalesce all High Risk FYI Flags into 1 cell per patient
(
    SELECT fyi2.PATIENT_ID
         , STRING_AGG(fyi2.NAME, ' | ') AS "High Risk Flag"
    FROM
    (
        SELECT DISTINCT 
               fyi.PATIENT_ID
             , fyicat.NAME
        FROM PATIENT_FYI_FLAGS fyi
             LEFT JOIN ZC_BPA_TRIGGER_FYI fyicat ON fyi.PAT_FLAG_TYPE_C = fyicat.BPA_TRIGGER_FYI_C
        WHERE fyi.PAT_FLAG_TYPE_C IN('1011', '1012', '2301', '2302', '2310', '2317')
             AND fyi.ACTIVE_C = '1'
    ) AS fyi2
    GROUP BY fyi2.PATIENT_ID
) AS hrfyi ON #DICohort.[Pat ID] = hrfyi.PATIENT_ID;
SELECT *
FROM #DICohortwithFlags;

/*******************************
Determine if Letter or Portal
*******************************/

SELECT pat.PAT_ID "Pat ID"
     , pat.PAT_NAME "Patient Name"
     , CAST(pat.BIRTH_DATE AS DATE) "DOB"
     , patfact.AGE_YEARS "Patient Age"
       --    , patmyc.MYCHART_STATUS_C
     , patmycstat.NAME "Patient Portal Status"
     , CAST(mycpataccount.LAST_LOGIN_TIME AS DATE) "Last Patient Login"
     , mycpat.PAT_NAME "Proxy Name"
     , proxy.PROXY_WPR_ID "Proxy WPR"
       --     , proxy.PROXY_STATUS_C
     , mcstatus.NAME "Proxy Status"
     , CAST(mycpat.LAST_LOGIN_TIME AS DATE) "Last Proxy Login"
INTO #CommunicationMode
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
    SELECT di.[Pat ID]
    FROM #DICohort di
)
      AND ((patfact.AGE_YEARS > 17
            AND patmyc.MYCHART_STATUS_C = '1'
            AND mycpataccount.LAST_LOGIN_TIME > '2023-05-23')
           OR (proxy.PROXY_WPR_ID <> ''
               AND mycpat.LAST_LOGIN_TIME > '2023-05-23'
               AND proxy.PROXY_STATUS_C <> '2'));

/***********************************************************
Find the Service Area of the Patient's Most Recent Encounter
***********************************************************/

SELECT patenc.PAT_ID
     , patenc.PAT_ENC_CSN_ID "CSN"
     , dep.SERV_AREA_ID "Service Area"
     , COALESCE(CAST(patenc.HOSP_ADMSN_TIME AS DATE), CAST(patenc.APPT_TIME AS DATE), CAST(patenc.CONTACT_DATE AS DATE)) "Encounter Date"
     , ROW_NUMBER() OVER(PARTITION BY patenc.PAT_ID
       ORDER BY COALESCE(CAST(patenc.HOSP_ADMSN_TIME AS DATE), CAST(patenc.APPT_TIME AS DATE), CAST(patenc.CONTACT_DATE AS DATE)) DESC
              , patenc.PAT_ENC_CSN_ID DESC) AS EncounterRank
INTO #RankEncounters
FROM PAT_ENC patenc
     LEFT JOIN PAT_ENC_HSP hsp ON patenc.PAT_ENC_CSN_ID = hsp.PAT_ENC_CSN_ID
     LEFT JOIN CLARITY_DEP dep ON patenc.EFFECTIVE_DEPT_ID = dep.DEPARTMENT_ID
WHERE patenc.ENC_TYPE_C IN('3', '49', '53', '76', '101', '108', '2532', '108', '1003', '1200', '1201', '1214', '2537')
     AND (patenc.APPT_STATUS_C IS NULL
          OR patenc.APPT_STATUS_C NOT IN('3', '4'))
AND (hsp.ADMIT_CONF_STAT_C IS NULL
     OR hsp.ADMIT_CONF_STAT_C NOT IN(2, 3))
AND COALESCE(CAST(patenc.HOSP_ADMSN_TIME AS DATE), CAST(patenc.APPT_TIME AS DATE), CAST(patenc.CONTACT_DATE AS DATE)) < '2023-09-30'
AND patenc.PAT_ID IN
(
    SELECT di.[Pat ID]
    FROM #DICohort di
)
ORDER BY patenc.PAT_ID
       , EncounterRank;
--SELECT * From #RankEncounters RE
--Order By RE.PAT_ID, RE.EncounterRank ASC

/*******************************
Bring it all together
*******************************/

--SELECT re.PAT_ID "Patient ID"
--     , re.[Service Area] "Service Area"
--FROM #RankEncounters RE
--WHERE RE.EncounterRank = 1;

SELECT di.*
     , CASE
           WHEN re.[Service Area] = 10
           THEN 'RCH'
           WHEN re.[Service Area] = 2010
           THEN 'RMH'
           WHEN re.[Service Area] = 3010
           THEN 'RWH'
           WHEN re.[Service Area] = 4010
           THEN 'PMCC'
           ELSE ''
       END AS "Service Area"
     , CASE
           WHEN EXISTS
(
    SELECT comms.[Pat ID]
    FROM #CommunicationMode comms
    WHERE comms.[Pat ID] = di.[Pat ID]
)
           THEN 'Portal'
           ELSE 'Letter'
       END AS "Comms Mode"
FROM #DICohortwithFlags di
     LEFT JOIN #RankEncounters re ON di.[Pat ID] = re.PAT_ID
                                     AND re.EncounterRank = 1;