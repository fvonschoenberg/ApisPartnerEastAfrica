##################################################################
# Steps:
# 1. Define parameters. For the first run, you probably want to leave them unchanged, before you know the data better.
# 2. Import data from excel files and clean it. This includes LP data, write-off data, and FX data
# 3. Label loans. This includes PAR status, refinancing status, potentially unflagged refinanced/restructured
# 4. Add repayment flag, based on how the loan's principal amount was reduced vs the expected principal repayments
# 5. Add the next month status of PAR, refinancing status etc.
# 6. Check the result (to be extended)
# 7. Save the data as migrationData.rds (for Power BI and R) and migrationData.csv (for Excel)
# 8. Calculate data for vintage curves, save output to Vintage.csv and Vintage.rds
# 9. Calculate migration matrices and PDs (not necessary if you do this in Excel instead) - NOT COMPLETE!!!
##################################################################

# Load dependencies and install if necessary
if (!require('installr')) install.packages('installr')
library(installr)
installr::updateR(fast = TRUE)

libraries = c("readxl","data.table", "readr", "lubridate","stringr",  "dplyr","tidyr", "stringi", "expm",
              "openxlsx", "ggplot2",  "summarytools")

lapply(libraries, function(x) if (!(x %in% installed.packages())) {
  install.packages(x)
})

lapply(libraries, library, quietly = TRUE, character.only = TRUE)

####################################################################################################################################
# 1. Define parameters. For the first run, you probably want to leave them unchanged, before you know the data better.
####################################################################################################################################

# Create the PAR buckets. They need to be in order best to worst for contamination etc. to work
# The numbering should be in the order you want to see the migration matrices, whereas the order of the vector is from best to worst
PARbucketLabels <- c("00 Repaid", "02 No arrears",	"01 Moratorium or Grace Period", "03 PAR 1-30",	"04 PAR 31-60",	"05 PAR 61-90",	
                     "06 PAR 91-120",	"07 PAR 121-150",	"08 PAR 151-180",	"09 PAR 181-210", "10 PAR 211-240", "11 PAR 241-270", "12 PAR 271-300", "13 PAR 301-330", "14 PAR 331-360", "15 PAR > 360", 
                     "16 Potential WO", "17 Written off")

# Group PAR buckets into the levels we want to see for the IFRS migration - set the labels in the order as above, 
# but with the same label for buckets we want to group
PARbucketLabels_IFRS <- c("00 Repaid", "02 No arrears", "01 Moratorium or Grace Period", "03 PAR 1-30",	"04 PAR 31-60",	"05 PAR 61-90", 
                          rep("06 PAR > 90", 10), 
                          "17 Written off", "17 Written off")

# Define for a loan to be flagged as Potential WO: what PAR bucket does it need to have to be flagged at the time it disappeared? Must be one of the PARbucketLabels buckets
PARbucketLimitForPotentialWO <- "15 PAR > 360"

# Define name for fixed interest rate types that match what the client filled out in the Info request. Must include at least one type, even if there's nothing filled out in the Info request
FixedInterestRateTypes <- c("Fixed")

# Define the amount outstanding that is considered to be repaid. Note that this is in the respective currency of the loan
AmountOutstandingThatIsConsideredRepaid <- 1

# Define the headers of the columns. They have to be in the order of the source file and use the exact names below
# If we use a format that is not in the Info request, reorder the below headers to match the source file and remove the ones that don't exist. 
# The variables listed as Required in the manual have to exist
# LPDataInputHeaders is in case the input files have different column order from our request, missing or extra columns
LPDataInputHeaders <- c("ReportDate", "LoanNumber", "ClientNumber", 
                   # REMOVE CLIENT NAME AFTER WE ADJUST THE INFO REQUEST!
                   "ClientName",
                   "ClientType", "Branch", "ProductType", "PledgedForFunding", "BusinessSector", 
                   "BusinessSubSector", "Region", "PurposeLoan", "InitialLO", "CurrentLO", 
                   "GroupLoan", "GroupNumber", "SubGroupNumber", "CashCollateral", 
                   "CurrencyLoan", "DisbursementDate", "DisbursedAmountCurrencyLoan", 
                   "ContractualMaturityDate", "RepaymentFrequency", # add method of computing instalments
                   "ArrearsDays", "MaximumArrearsDays", 
                   "PrincipalCurrencyLoan", 
                   "YearlyNominalIR", "TypeIR", "VariableIRSpread", 
                   "YearlyEffectiveIR", "AccruedIRCurrencyLoan", 
                   "AccruedPenaltyCurrencyLoan", 
                   "UnmortizedFeesCurrencyLoan", 
                   "OverduePrincipalCurrencyLoan", 
                   "OverdueInterestCurrencyLoan", 
                   "Restructured", "Refinanced", "NumberRestructurings", 
                   "LoanNumberPreviousLoan", "RegulatorRestructuringClassification", 
                   "InternalRestructuringClassification", "MoratoriumStatus", 
                   "EndMoratoriumDate", "GracePeriodStatus", 
                   "EndGracePeriodDate", "InternalRiskClassification", 
                   "RegulatorRiskClassification", "RelatedPartiesWithBank", 
                   # May need to change the below ones
                   "RegulatorLLPPrincipalCurrencyLoan", 
                   "RegulatorLLPAccruedInterestCurrencyLoan", 
                   "RegulatorLLPPenaltyInterestCurrencyLoan", 
                   "IFRSLLPPrincipalCurrencyLoan", 
                   "IFRSLLPAccruedInterestCurrencyLoan", 
                   "IFRSLLPPenaltyInterestCurrencyLoan")

# here is the headers we have in our request, so the standard. The code will check if they were created in the 1st step
# otherwise it will add any missing columns. This might create NAs errors so go through the code step by step. 
LPDataHeaders <- c("ReportDate", "LoanNumber", "ClientNumber",
                   "ClientType", "Branch", "ProductType", "PledgedForFunding", "BusinessSector",
                   "BusinessSubSector", "Region", "PurposeLoan", "InitialLO", "CurrentLO",
                   "GroupLoan", "GroupNumber", "SubGroupNumber", "CashCollateral",
                   "CurrencyLoan", "DisbursementDate", "DisbursedAmountCurrencyLoan",
                   "ContractualMaturityDate", "RepaymentFrequency",
                   "ArrearsDays", "MaximumArrearsDays",
                   "PrincipalCurrencyLoan",
                   "YearlyNominalIR", "TypeIR", "VariableIRSpread",
                   "YearlyEffectiveIR", "AccruedIRCurrencyLoan",
                   "AccruedPenaltyCurrencyLoan",
                   "UnmortizedFeesCurrencyLoan",
                   "OverduePrincipalCurrencyLoan",
                   "OverdueInterestCurrencyLoan",
                   "Restructured", "Refinanced", "NumberRestructurings",
                   "LoanNumberPreviousLoan", "RegulatorRestructuringClassification",
                   "InternalRestructuringClassification", "MoratoriumStatus",
                   "EndMoratoriumDate", "GracePeriodStatus",
                   "EndGracePeriodDate", "InternalRiskClassification",
                   "RegulatorRiskClassification", "RelatedPartiesWithBank",
                   "RegulatorLLPPrincipalCurrencyLoan",
                   "RegulatorLLPAccruedInterestCurrencyLoan",
                   "RegulatorLLPPenaltyInterestCurrencyLoan",
                   "IFRSLLPPrincipalCurrencyLoan",
                   "IFRSLLPAccruedInterestCurrencyLoan",
                   "IFRSLLPPenaltyInterestCurrencyLoan")
                 

# Loan types where increases in principal amounts are OK (have to match the names in the ProductType), i.e. levels(LPData$ProductType) after you're read in LPData
LoanTypesWithChangingPrincipal <- c("Corp OD Acc", "Corporate Ovedraft Account")


# Reasons for flagging a loan as (potential) restructured/refinanced/WO. If you change names here, make sure to replace all
# In order from best to worst
TypeOfRefinancedOrRestructuredLabels = c("Principal increased in PAR1-30",
                         "Replaced PAR1-30 loan", 
                         "Replaced by refinanced loan", 
                         "Reported as refinanced in past", 
                         "Reported as refinanced",
                         "Uneven disbursed amount", 
                         "Changed maturity or interest",
                         "Principal increased in PAR30",
                         "Replaced (by) loan in PAR30", 
                         "Replaced by restructured loan", 
                         "Reported as restructured in past",
                         "Reported as restructured",
                         "Potential WO",
                         "Written off")

# Types of potential refinancing or restructuring that will not be flagged as additional restructuring or re-restructured
# These will still be counted as Potential refi/restr, since that can be filtered in the output Excel
TypesOfRefiOrRestrNotToCount <- factor(c("Principal increased in PAR30", "Principal increased in PAR1-30"), 
                                         levels = TypeOfRefinancedOrRestructuredLabels)

# Define number of months of grace period expected before the loan starts repaying (after one month after disbursement has passed)
GracePeriodInMonths <- 1

# Define the cutoff points for the output indicators
CutOffForRepaidOfExpected <- 0.4
CutOffForMonthsOfTooHighOutstanding <- 3

# Define lookback period in number of months for averaging the principal repayments (must not be longer than the number of reporting months available)
LookbackInMonths <- 10

# Define which one is the foreign currency. We will assume that FCY amount = LCY amount / FCY rate
FCY <- "USD"


####################################################################################################################################
# 2. Import data from excel files and clean it. This includes LP data, write-off data, and FX data
# NOTE: before running this code, go through the excel files and make sure the columns are in the right order
####################################################################################################################################


# Ask for where to save output data files and set the working directory to here
SaveLocation <- choose.dir(default = getwd(), caption = "Select where to save output data")
setwd(SaveLocation)

# Import LP data; ask user where they are
LPDataFiles <- choose.files(caption = "Select files to import portfolio data", default = getwd())
ReadLocation <- dirname(LPDataFiles)[1]
LPDataFiles <- basename(LPDataFiles)

# For a big dataset: THIS IMPORT TAKES A LONG TIME! If it's been done once, do instead: LPData <- read_rds("LPData.rds")
setwd(ReadLocation)
i = 1
LPData <- list()
# str_sub(filenames, last characters of the file name where it should start checking,
# last charactes of the file where the name of the file finishes)
if (str_sub(LPDataFiles[1], -3, -1) == "lsx") {
  for (filename in LPDataFiles) {
    print(filename)
# skip in read_xlsx is number of rows to skip at start (leading empty rows are automatically skipped)
       LPData[[i]] <- read_xlsx(filename, sheet = "Portfolio OnBalance", col_types= "text", skip = 3)[-1, c(1:length(LPDataInputHeaders))]
    i <- i+1
  }
} else if (str_sub(LPDataFiles[1], -3, -1) == "xls") {
  for (filename in LPDataFiles) {
    print(filename)
    LPData[[i]] <- read_xls(filename, sheet = "Portfolio OnBalance", col_types= "text", skip = 3)[-1, c(1:length(LPDataInputHeaders))]
    i <- i+1
  }
} else {
  print("Source code is not excel; please use a different read function")
}
setwd(SaveLocation)

# Change the YES or NO if the input is in spanish
LPData <- rapply(LPData, function(x) ifelse(x=="NULL",NA,x), how = "replace")
LPData <- rapply(LPData, function(x) ifelse(x=="YES","Yes",x), how = "replace")
LPData <- rapply(LPData, function(x) ifelse(x=="NO","No",x), how = "replace")

# Transform the information extracted into a data.table format (faster to make calculations)
LPData <- data.table(rbindlist(LPData))
LPData <- setnames(LPData, names(LPData), LPDataInputHeaders)
names(LPData)
LPData[,LPDataHeaders[!(LPDataHeaders %in% colnames(LPData))]] <- NA
rm(LPDataHeaders, LPDataInputHeaders)

# check how many NAs
purrr::map_df(LPData, ~sum(is.na(.))) %>% as.data.frame()


# Check the number of loans in each date
LPData %>%
  group_by(ReportDate) %>%
  tally()



# ----------------------- Clean & complete data

# Transform values to correct types

# Make sure no special characters
LPData <- LPData %>% 
  mutate_all(funs(stri_encode(., from = "", to = "UTF-8")))

# Change data types where they should be numbers and dates
LPData <- LPData %>% 
  mutate_at(vars(ReportDate, CashCollateral,LoanCycle, DisbursementDate,
                 ContractualMaturityDate,DisbursedAmountCurrencyLoan,PrincipalCurrencyLoan,
                 AccruedIRCurrencyLoan,AccruedPenaltyCurrencyLoan,ArrearsDays,
                 YearlyNominalIR, MaximumArrearsDays,VariableIRSpread,YearlyEffectiveIR,
                 UnmortizedFeesCurrencyLoan,NumberRestructurings,EndMoratoriumDate, 
                 EndGracePeriodDate,RegulatorLLPPrincipalCurrencyLoan,
                 RegulatorLLPAccruedInterestCurrencyLoan,RegulatorLLPPenaltyInterestCurrencyLoan,
                 IFRSLLPPrincipalCurrencyLoan,IFRSLLPAccruedInterestCurrencyLoan,
                 IFRSLLPPenaltyInterestCurrencyLoan),
                                  funs(as.numeric)) %>%
  mutate_at(vars(ReportDate, DisbursementDate, ContractualMaturityDate), 
            # due to an error in Excel's dates, the origin that gives the correct dates is as below
            funs(as.Date(., origin = "1899-12-30")))

# If the TypeIR is missing, we assume it to be fixed
LPData[is.na(LPData$TypeIR), "TypeIR"] <- FixedInterestRateTypes[1]

# Change data types where they should be factors
LPData <- LPData %>% 
  mutate_at(vars(ClientType, Branch, ProductType, PledgedForFunding, BusinessSector, 
           BusinessSubSector, Region, PurposeLoan, 
           GroupLoan, CurrencyLoan, RepaymentFrequency, 
           TypeIR, Restructured, Refinanced, 
           RegulatorRestructuringClassification, 
           InternalRestructuringClassification, MoratoriumStatus, 
           GracePeriodStatus,
           InternalRiskClassification, 
           RegulatorRiskClassification, RelatedPartiesWithBank),
           funs(factor))


# Check principal amounts (sum includes different currencies)
LPData %>%
  group_by(ReportDate) %>%
  summarise(Princ = sum(PrincipalCurrencyLoan))


# Remove NAs from critical columns
LPData[which(is.na(LPData$Refinanced)), "Refinanced"] <- "No"
LPData[which(is.na(LPData$Restructured)), "Restructured"] <- "No"

# Set client types to only the first word in client type
# Note: this needs adjustment in case two types have the same first word
levels(LPData$ClientType)
levels(LPData$ClientType) <- factor(word(levels(LPData$ClientType), 1))


# Set the report date to the first of the reporting month; easier to handle later
LPData$ReportDate <- floor_date(LPData$ReportDate, "month")

# Inspect
str(LPData)
summary(LPData)


# ----------------------- Import Write-off data for all dates

# Define the headers of the columns
WODataHeaders <- c("ReportDate", "LoanNumber", "ClientNumber", "WriteOffDate", 
                   "PARatWriteOff",	"PrincipalAtWriteOffCurrencyLoan",
                   "CurrencyLoan",
                   "AccruedInterestAtWriteOffCurrencyLoan",	"AccruedPenaltiesAtWriteOffCurrencyLoan",
                   "PrincipalCurrencyLoan",	"AccruedInterestCurrencyLoan",	
                   "AccruedPenaltiesCurrencyLoan")

# Import data. If it's been done once, do instead: WOData <- read_rds("WOData.rds")
setwd(ReadLocation)
i = 1
WOData <- list()
if (str_sub(LPDataFiles[1], -3, -1) == "lsx") {
  for (filename in LPDataFiles) {
    print(filename)
    WOData[[i]] <- read_xlsx(filename, sheet = "Write Offs", col_types= "text", skip = 0)[, c(1:12)]
    i <- i+1
  }
} else if (str_sub(LPDataFiles[1], -3, -1) == "xls") {
  for (filename in LPDataFiles) {
    print(filename)
    WOData[[i]] <- read_xls(filename, sheet = "Write Offs", col_types= "text", skip = 0)[, c(1:12)]
    i <- i+1
  }
} else {
  print("Source code is not excel; please use a different read function")
}
setwd(SaveLocation)


# transform the information extracted into a data.table format (faster to make calculations)
WOData <- data.table(rbindlist(WOData))
WOData <- setnames(WOData, names(WOData), WODataHeaders)
rm(WODataHeaders)

# Check the number of loans in each date
WOData %>%
  group_by(ReportDate) %>%
  tally()


# ----------------------- Clean WO data
# Transform values to correct types

# Make sure no special characters
WOData <- WOData %>% 
  mutate_all(funs(stri_encode(., from = "", to = "UTF-8")))

# Change data types where they should be numbers and dates
WOData <- WOData %>% 
  mutate_at(vars(ReportDate, WriteOffDate:PrincipalAtWriteOffCurrencyLoan,
                 AccruedInterestAtWriteOffCurrencyLoan:AccruedPenaltiesCurrencyLoan),
            funs(as.numeric)) %>%
  mutate_at(vars(ReportDate, WriteOffDate), 
            # due to an error in Excel's dates, the origin that gives the correct dates is as below
            funs(as.Date(., origin = "1899-12-30")))

WOData <- WOData %>% 
  mutate_at(vars(CurrencyLoan),
            funs(factor))

# Check principal amounts (sum includes different currencies)
WOData %>%
  group_by(ReportDate) %>%
  summarise(Princ = sum(PrincipalAtWriteOffCurrencyLoan))


# Inspect
str(WOData)
summary(WOData)

# Save data 
write_rds(WOData, paste0(SaveLocation, "\\", "WOData.rds"))



# ----------------------- Import FX rates; usually just one file has all historic data
setwd(ReadLocation)
FXDataFiles <- choose.files(caption = "Select files to import FX data (normally the latest Info Pack file)")
ReadLocation <- dirname(FXDataFiles)[1]


# Define the headers of the columns
FXDataHeaders <- c("ReportDate", "Currency", "FXRate")

# Import data. If it's been done once, do instead: FXData <- read_rds("FXData.rds")
i = 1
FXData <- list()
if (str_sub(FXDataFiles[1], -3, -1) == "lsx") {
  for (filename in FXDataFiles) {
    print(filename)
    FXData[[i]] <- read_xlsx(filename, sheet = "FX rates", col_types= "text", skip = 0)[-1, c(1:3)]
    i <- i+1
  }
} else if (str_sub(FXDataFiles[1], -3, -1) == "xls") {
  for (filename in FXDataFiles) {
    print(filename)
    FXData[[i]] <- read_xls(filename, sheet = "FX rates", col_types= "text", skip = 0)[-1, c(1:3)]
    i <- i+1
  }
} else {
  print("Source code is not excel; please use a different read function")
}
setwd(ReadLocation)

# Transform the information extracted into a data.table format (faster to make calculations)
FXData <- data.table(rbindlist(FXData))
FXData <- setnames(FXData, names(FXData), FXDataHeaders)
rm(FXDataHeaders)

# Remove duplicate date-currency combinations
FXData <- unique(FXData, by = c("ReportDate", "Currency"))

# Check the number of rates for each date
FXData %>%
  group_by(ReportDate) %>%
  tally()


# ----------------------- Clean FX data
# Transform values to correct types

# Make sure no special characters
FXData <- FXData %>% 
  mutate_all(funs(stri_encode(., from = "", to = "UTF-8")))

# Change data types where they should be numbers and dates
FXData <- FXData %>% 
  mutate_at(vars(ReportDate, FXRate),
            funs(as.numeric)) %>%
  mutate_at(vars(ReportDate), 
            # due to an error in Excel's dates, the origin that gives the correct dates is as below
            funs(as.Date(., origin = "1899-12-30")))

# Change data types where they should be factors
FXData <- FXData %>% 
  mutate_at(vars(Currency),
            funs(factor))

# Find local currency code - guess that the code listed as currency for loans but that does not appear in the FX list is the local currency
LCY_code <- data.frame(Curr = levels(LPData$CurrencyLoan)) %>% 
  anti_join(
    data.frame(Curr = levels(FXData$Currency)),
    by = "Curr") 

# If the guess didn't work, ask user for the local currency
if (length(LCY_code) != 1 ) {
  LCY_code <- readline(prompt="Enter the local currency code: ")
}

# Add local currency to the factor levels
levels(FXData$Currency) <- c(levels(FXData$Currency), as.character(LCY_code[1,1]))

# Add local currency rates to the FX data
FXData <- FXData %>%
  # Create a list with only the local currency for each unique report date
  select(ReportDate) %>% unique() %>%
  mutate(Currency = factor(LCY_code[1,1], levels = levels(FXData$Currency)), 
         FXRate = 1) %>%
  bind_rows(FXData) %>%
  mutate(ReportDate = floor_date(ReportDate, "month"))

# Inspect
str(FXData)
summary(FXData)

# Check for duplicates - this must be empty
LPData[(duplicated(LPData[,c("LoanNumber", "ReportDate")])),c("LoanNumber", "ReportDate")]


# Save data 
write_rds(FXData, paste0(SaveLocation, "\\", "FXData.rds"))

# Save data 
write_rds(LPData, paste0(SaveLocation, "\\", "LPData.rds"))

# Clean
rm(LCY_code, FXDataFiles)












####################################################################################################################################
# 3. Label loans. This includes PAR status, refinancing status, potentially unflagged refinanced/restructured
####################################################################################################################################

# Code below is in case you have not just run the code above
# SaveLocation <- choose.dir(caption = "Select the location where R has stored portfolio data")
# Code if you don't want to use the prompt above: SaveLocation <- "C:\\Users\\Langefors\\Documents\\ECL approach\\R data\\Full data"
# LPData <- read_rds(paste0(SaveLocation, "\\", "LPData.rds"))
# WOData <- read_rds(paste0(SaveLocation, "\\", "WOData.rds"))
# FXData <- read_rds(paste0(SaveLocation, "\\", "FXData.rds"))


# ---------------------------- Add Total exposure measures and LCY equivalent

# Add FX rates to the dataset
LPData$CurrencyLoan <- as.character(LPData$CurrencyLoan)
FXData$Currency <- as.character(FXData$Currency)

# Merge in the FX rates into the main dataset
LPData <- LPData %>%
  left_join(FXData, by = c("CurrencyLoan" = "Currency",
                           "ReportDate" = "ReportDate")) 

LPData$CurrencyLoan <- as.factor(LPData$CurrencyLoan)

# Replace NAs by zeros for the amounts we need
LPData <- LPData %>% 
  mutate(PrincipalCurrencyLoan = replace_na(PrincipalCurrencyLoan, 0),
         AccruedIRCurrencyLoan = replace_na(AccruedIRCurrencyLoan, 0),
         AccruedPenaltyCurrencyLoan = replace_na(AccruedPenaltyCurrencyLoan, 0),
         CashCollateral = replace_na(CashCollateral, 0)) 

# Total exposure
LPData <- LPData %>%
  mutate(TotalExposure = PrincipalCurrencyLoan
         + AccruedIRCurrencyLoan
         + AccruedPenaltyCurrencyLoan
         - CashCollateral,
         NetPrincipal = PrincipalCurrencyLoan
         - CashCollateral,
         PrincipalLCYequivalent = PrincipalCurrencyLoan * FXRate,
         AccruedIRLCYequivalent = AccruedIRCurrencyLoan * FXRate,
         TotalExposureLCYequivalent = TotalExposure * FXRate,
         NetPrincipalLCYequivalent = NetPrincipal * FXRate
  ) 




# ---------------------------- Create PAR buckets, flag write offs and refinanced

# Add write off date to LP data
LPData <- WOData %>%
  filter(!duplicated(LoanNumber)) %>%
  select(LoanNumber, WriteOffDate) %>%
  right_join(LPData, by = "LoanNumber")

# Create PAR buckets. The numbers refer to the order they are in in PARbucketLabels. NOTE: these are NOT the same as the numbers they have
LPData <- mutate(LPData, PARbucket = 2) 
# If nothing is entered in ArrearsDays, set to No arrears
LPData[which(is.na(LPData$ArrearsDays)), "PARbucket"] <- 2
# Calculate the PAR bucket
LPData$PARbucket <- ceiling(LPData$ArrearsDays / 30) + 2
# After No arrears, the Moratorium or Grace needs 1 space
LPData$PARbucket[LPData$ArrearsDays > 0] <- LPData$PARbucket[LPData$ArrearsDays > 0] + 1
# No higher PAR buckets than PAR > 360
LPData$PARbucket[(LPData$ArrearsDays > 360)] <- 16
# Set loans with small balance to Repaid
LPData$PARbucket[LPData$PrincipalCurrencyLoan <= AmountOutstandingThatIsConsideredRepaid] <- 1

PARbucketLevels <- as.character(1:length(PARbucketLabels))

# Add labels to the PAR buckets
LPData$PARbucket <- factor(LPData$PARbucket, levels = PARbucketLevels,
                           labels = PARbucketLabels, ordered = TRUE)



# Flag loans as restructuring / refinancing reported
LPData <- LPData %>%
  mutate(ReportedRestructuring = if_else(Restructured == "Yes", "Restructured",
                                         if_else(Refinanced == "Yes", "Refinanced", "Not restructured / refinanced")))


# Flag potentially refinanced loans:

# Clients with loans disbursed this month 
NewLoans <- LPData %>%
  filter(ReportDate == floor_date(DisbursementDate, "month")) %>%
  select(ClientNumber, LoanNumber, ReportDate, Restructured, Refinanced) 

# Find clients that had loans that loans outstanding before the new loan was disbursed
# And where these loans had a balance > 0
ReplacedLoans <- LPData %>%
  mutate(NextMonth = ReportDate %m+% months(1)) %>%
  select(ReportDate, NextMonth, ClientNumber, LoanNumber, PrincipalCurrencyLoan, ArrearsDays) %>%
  inner_join(NewLoans, by = c("ClientNumber" = "ClientNumber", "NextMonth" = "ReportDate"),
             suffix = c("_OldLoan", "_NewLoan")) %>% 
  filter(LoanNumber_OldLoan != LoanNumber_NewLoan, 
         PrincipalCurrencyLoan > 0) %>%
  select(-c(ArrearsDays, PrincipalCurrencyLoan))


# Find if any of the old loans were ever restructured or refinanced
PreviouslyRestrOrRefi <- ReplacedLoans %>%
  select(ReportDate, NextMonth, ClientNumber, LoanNumber_OldLoan, LoanNumber_NewLoan) %>%
  # Find the restructuring/refinancing status of the replaced loans
  left_join(
    select(LPData, ClientNumber, LoanNumber, Restructured, Refinanced), 
    by = c("LoanNumber_OldLoan" = "LoanNumber", "ClientNumber" = "ClientNumber")) %>%
  group_by(ClientNumber, LoanNumber_OldLoan) %>%
  # flag the loan as RestrPreviously/RefiPreviously if it was ever restructured/refinanced
  summarise(Restr = sum(Restructured == "Yes"),
            Refi = sum(Refinanced == "Yes")) %>%
  mutate(RestrPreviously = if_else(Restr > 0, "Yes", "No"),
         RefiPreviously = if_else(Refi > 0, "Yes", "No")) %>%
  # find the loan number of the new loan that matches the old (replaced) loan
  right_join(ReplacedLoans, by = c("LoanNumber_OldLoan" = "LoanNumber_OldLoan", "ClientNumber" = "ClientNumber")) %>%
  ungroup() %>%
  select(ClientNumber, LoanNumber_NewLoan, RestrPreviously, RefiPreviously) %>%
  filter(!duplicated(LoanNumber_NewLoan))



# Find potential refinanced: start from all loans that were replaced by a new loan
HiddenRefinanced <- ReplacedLoans %>%
  # Add information on arrears days and maturity date of the replaced loans
  left_join(
    select(LPData, ReportDate, LoanNumber, ArrearsDays, ContractualMaturityDate), 
    by = c("LoanNumber_OldLoan" = "LoanNumber", "ReportDate" = "ReportDate")) %>%
  # Add information on whether loans were previously refinanced
  left_join(
    select(PreviouslyRestrOrRefi, LoanNumber_NewLoan, RefiPreviously),
    by = "LoanNumber_NewLoan") %>%
  # find remaining maturity of the old loan
  mutate(RemainingMaturityDays = as.numeric(
    difftime( ContractualMaturityDate, 
              (ReportDate %m+% months(1) %m-% days(1)), 
              units = "days"))) %>%
  # find max arrears and min remaining maturity by client
  group_by(ClientNumber, ReportDate, RefiPreviously) %>%
  summarise(MaxArrears = max(ArrearsDays, na.rm = T),
            MaxRemainingMaturity = max(RemainingMaturityDays)) %>%
  ungroup() %>%
  # add information on the new loan
  mutate(ReportDate = ReportDate %m+% months(1)) %>%
  # select clients thave have 1-30 PAR days and remaining maturity over 2 months
  left_join(ReplacedLoans, by = c("ClientNumber" = "ClientNumber", "ReportDate" = "NextMonth")) %>%
  filter( (MaxArrears > 0 & MaxArrears <= 30 & MaxRemainingMaturity > 60 & Refinanced == "No" & Restructured == "No") |
            (RefiPreviously == "Yes" & Refinanced == "No" & Restructured == "No")) %>%
  rename(ReportDate_NewLoan = ReportDate) %>%
  # Add reason for flagging
  mutate(TypeOfRefinancedOrRestructured = factor(which(TypeOfRefinancedOrRestructuredLabels == "Replaced PAR1-30 loan"), 
                                                 levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                 labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE)) %>%
  select(-ReportDate.y)


# Find potential restructured: start from all loans that were replaced by a new loan
HiddenRestructured <- ReplacedLoans %>%
  # Add information on arrears days and maturity date of the replaced loans
  left_join(
    select(LPData, ReportDate, LoanNumber, ArrearsDays, ContractualMaturityDate), 
    by = c("LoanNumber_OldLoan" = "LoanNumber", "ReportDate" = "ReportDate")) %>%
  # Add information on if loans were previously restructured
  left_join(
    select(PreviouslyRestrOrRefi, LoanNumber_NewLoan, RestrPreviously),
    by = "LoanNumber_NewLoan") %>% 
  # find max arrears and min remaining maturity by client
  group_by(ClientNumber, ReportDate, RestrPreviously) %>%
  summarise(MaxArrears = max(ArrearsDays, na.rm = T)) %>%
  ungroup() %>%
  # add information on the new loan
  mutate(ReportDate = ReportDate %m+% months(1)) %>%
  # select clients thave have PAR days >30
  left_join(ReplacedLoans, by = c("ClientNumber" = "ClientNumber", "ReportDate" = "NextMonth")) %>%
  filter( (MaxArrears > 30 & Restructured == "No") | 
            (RestrPreviously == "Yes" & Restructured == "No")) %>%
  rename(ReportDate_NewLoan = ReportDate) %>%
  # Determine flagging reason
  mutate(TypeOfRefinancedOrRestructured = if_else(RestrPreviously == "Yes",
                                                  factor(which(TypeOfRefinancedOrRestructuredLabels == "Reported as restructured in past"), 
                                                         levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                         labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE),
                                                  # if it wasn't restructured previously, it's flagged due to replacement of loans in PAR30
                                                  factor(which(TypeOfRefinancedOrRestructuredLabels == "Replaced (by) loan in PAR30"),
                                                         levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                         labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE))) %>%
  select(-ReportDate.y ) 



# Add loans where disbursed amounts are not even
HiddenRestructured <- NewLoans %>%
  filter(Restructured == "No") %>%
  left_join(select(LPData, LoanNumber, DisbursedAmountCurrencyLoan), 
            by = "LoanNumber") %>%
  # remove duplicates, since we don't need an entry for each report date 
  unique() %>%
  rename(LoanNumber_NewLoan = LoanNumber, ReportDate_NewLoan = ReportDate) %>%
  # filter for disbursed amounts that are not whole numbers (non-zero remainder of division with 1)
  filter( (DisbursedAmountCurrencyLoan %% 1) != 0) %>%
  mutate(TypeOfRefinancedOrRestructured = factor(which(TypeOfRefinancedOrRestructuredLabels == "Uneven disbursed amount"), 
                                                 levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                 labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE)) %>%
  # mark these loans as potential restructured too
  select(-c(Restructured, Refinanced, ClientNumber)) %>%
  left_join(ReplacedLoans, 
            by = c("LoanNumber_NewLoan" = "LoanNumber_NewLoan", "ReportDate_NewLoan" = "NextMonth")) %>%
  select(-ReportDate) %>%
  bind_rows(HiddenRestructured) 


# Now we might have several rows for one loan; need to summarize them
HiddenRestructured <- HiddenRestructured %>%
  group_by(LoanNumber_NewLoan, ReportDate_NewLoan) %>%
  summarise(DisbursedAmountCurrencyLoan = sum(DisbursedAmountCurrencyLoan, na.rm = T),
            # use PAR30 as the flagging reason if the loan had both an uneven disbursement amount and PAR30 as reasons
            TypeOfRefinancedOrRestructured = if_else(sum(TypeOfRefinancedOrRestructured == "Reported as restructured in past", na.rm = T)>0,
                                                     factor(which(TypeOfRefinancedOrRestructuredLabels == "Reported as restructured in past"), 
                                                            levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                            labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE), 
                                                     if_else(sum(TypeOfRefinancedOrRestructured == "Replaced (by) loan in PAR30", na.rm = T)>0,
                                                             factor(which(TypeOfRefinancedOrRestructuredLabels == "Replaced (by) loan in PAR30"),
                                                                    levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                                    labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE),
                                                             factor(which(TypeOfRefinancedOrRestructuredLabels == "Uneven disbursed amount"),
                                                                    levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                                    labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE))),
            ClientNumber = first(ClientNumber),
            LoanNumber_OldLoan = first(LoanNumber_OldLoan),
            Restructured = if_else(sum(Restructured == "Yes", na.rm = T)>0,
                                   "Yes", "No"),
            Refinanced = if_else(sum(Refinanced == "Yes", na.rm = T)>0,
                                 "Yes", "No")) %>%
  ungroup()


# Flag loans as Potential restructured where maturity or interest rate is changed to next month and the loan was in PAR>30
HiddenRestructured <- LPData %>%
  select(ClientNumber, LoanNumber, ReportDate, ContractualMaturityDate, YearlyNominalIR, TypeIR, ArrearsDays, PARbucket, DisbursedAmountCurrencyLoan, Refinanced, Restructured) %>%
  # find maturity and interest rate next month
  mutate(ReportDate_prevMonth = ReportDate %m-% months(1)) %>%
  left_join(select(LPData, ReportDate, LoanNumber, ContractualMaturityDate, YearlyNominalIR),
            by = c("ReportDate_prevMonth" = "ReportDate", "LoanNumber" = "LoanNumber"), 
            suffix = c("_thisMonth", "_prevMonth")) %>%
  filter(
    # Select loans that existed previous month
    (!is.na(ContractualMaturityDate_prevMonth)) &
      # and that are not restructured 
      (Restructured != "Yes") &
      # and where maturity date became more than 2 months later
      (ContractualMaturityDate_thisMonth > (ContractualMaturityDate_prevMonth %m+% months(2))) |
      # or interest rate was lowered if the interest rate was fixed (if the change is >1%; we assume that otherwise, it's a numerical issue)
      ((TypeIR %in% FixedInterestRateTypes) & (YearlyNominalIR_thisMonth < YearlyNominalIR_prevMonth*0.99)) |
      # or the interest rate was increased and the loan was in PAR30
      ((YearlyNominalIR_thisMonth > YearlyNominalIR_prevMonth*1.01) & (ArrearsDays > 30 | PARbucket == "01 Moratorium or Grace Period"))) %>%
  # Change variables to match the HiddenRestructured table 
  mutate(Refinanced = as.character(Refinanced),
         Restructured = as.character(Restructured)) %>%
  # Remove variables 
  select(-c(ContractualMaturityDate_thisMonth, YearlyNominalIR_thisMonth, 
            ArrearsDays, PARbucket, ReportDate_prevMonth, ContractualMaturityDate_prevMonth, 
            YearlyNominalIR_prevMonth)) %>%
  # Rename variables to match HiddenRestructured
  rename(LoanNumber_NewLoan = LoanNumber,
         ReportDate_NewLoan = ReportDate) %>%
  # Remove loans already flagged as hidden restructured
  anti_join(HiddenRestructured,
            by = c("ReportDate_NewLoan" = "ReportDate_NewLoan", "LoanNumber_NewLoan" = "LoanNumber_NewLoan")) %>%
  mutate(TypeOfRefinancedOrRestructured = factor(which(TypeOfRefinancedOrRestructuredLabels == "Changed maturity or interest"),
                                                 levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                 labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE)) %>%
  # Add the existing HiddenRestructured
  bind_rows(HiddenRestructured) 



# Add refinance/restructuring flags to the main dataset

# Add NumberCalculatedRestructurings
LPData <- LPData %>% mutate(NumberCalculatedRestructurings = 0)


# Add refinancing flag for the new loan number
LPData <- HiddenRefinanced %>%
  select(ReportDate_NewLoan, LoanNumber_NewLoan, TypeOfRefinancedOrRestructured) %>%
  distinct(LoanNumber_NewLoan, ReportDate_NewLoan, .keep_all = TRUE) %>%
  # Flag these loans as potentially refinanced and add a number of restructurings, but only if the type of refinancing isn't in TypesOfRefiOrRestrNotToCount
  mutate(PotentialRefinanced = "Yes", 
         AdditionalNrRestr = if_else(TypeOfRefinancedOrRestructured %in% TypesOfRefiOrRestrNotToCount, 0, 1)) %>%
  right_join(LPData, by = c("LoanNumber_NewLoan" = "LoanNumber", "ReportDate_NewLoan" = "ReportDate")) %>%
  mutate(
    AdditionalNrRestr = replace_na(AdditionalNrRestr, 0),
    NumberCalculatedRestructurings = pmax(NumberCalculatedRestructurings, AdditionalNrRestr)) %>%
  rename(ReportDate = ReportDate_NewLoan, 
         LoanNumber = LoanNumber_NewLoan) %>%
  select(-AdditionalNrRestr)


# In case the loan number that got refinanced continues to be outstanding, mark that as refinanced too
LPData <- HiddenRefinanced %>%
  select(ReportDate_NewLoan, LoanNumber_OldLoan, TypeOfRefinancedOrRestructured) %>%
  distinct(ReportDate_NewLoan, LoanNumber_OldLoan, .keep_all = TRUE) %>%
  mutate(PotentialRefinanced = "Yes", 
         AdditionalNrRestr = if_else(TypeOfRefinancedOrRestructured %in% TypesOfRefiOrRestrNotToCount, 0, 1)) %>%
  right_join(LPData, by = c("LoanNumber_OldLoan" = "LoanNumber", "ReportDate_NewLoan" = "ReportDate")) %>%
  # Now we need to merge the PotentialRefinanced and TypeOfRefinancedOrRestructured info 
  mutate(PotentialRefinanced = if_else( (PotentialRefinanced.x == "Yes" & !is.na(PotentialRefinanced.x)) |
                                          (PotentialRefinanced.y == "Yes" & !is.na(PotentialRefinanced.y)),
                                        "Yes", "No"),
         TypeOfRefinancedOrRestructured = if_else(!is.na(TypeOfRefinancedOrRestructured.x),
                                                  TypeOfRefinancedOrRestructured.x, TypeOfRefinancedOrRestructured.y),
         AdditionalNrRestr = replace_na(AdditionalNrRestr, 0),
         NumberCalculatedRestructurings = pmax(NumberCalculatedRestructurings, AdditionalNrRestr)) %>%
  rename(ReportDate = ReportDate_NewLoan, LoanNumber = LoanNumber_OldLoan) %>%
  select(-c(PotentialRefinanced.x, PotentialRefinanced.y, TypeOfRefinancedOrRestructured.x, TypeOfRefinancedOrRestructured.y, AdditionalNrRestr))


# Add restructuring flag for the new loan number
LPData <- HiddenRestructured %>%
  select(ReportDate_NewLoan, LoanNumber_NewLoan, TypeOfRefinancedOrRestructured) %>%
  distinct(LoanNumber_NewLoan, ReportDate_NewLoan, .keep_all = TRUE) %>%
  mutate(PotentialRestructured = "Yes", 
         AdditionalNrRestr = if_else(TypeOfRefinancedOrRestructured %in% TypesOfRefiOrRestrNotToCount, 0, 1)) %>%
  right_join(LPData, by = c("LoanNumber_NewLoan" = "LoanNumber", "ReportDate_NewLoan" = "ReportDate")) %>%
  mutate(
    AdditionalNrRestr = replace_na(AdditionalNrRestr, 0),
    NumberCalculatedRestructurings = pmax(NumberCalculatedRestructurings, AdditionalNrRestr)) %>%
  rename(ReportDate = ReportDate_NewLoan, 
         LoanNumber = LoanNumber_NewLoan) %>%
  # Now we need to merge the TypeOfRefinancedOrRestructured info 
  mutate(TypeOfRefinancedOrRestructured = if_else(!is.na(TypeOfRefinancedOrRestructured.x),
                                                  TypeOfRefinancedOrRestructured.x, TypeOfRefinancedOrRestructured.y)) %>%
  select(-c(TypeOfRefinancedOrRestructured.x, TypeOfRefinancedOrRestructured.y, AdditionalNrRestr))


# In case the loan number that got restructured continues to be outstanding, mark that as restructured too
LPData <- HiddenRestructured %>%
  select(ReportDate_NewLoan, LoanNumber_OldLoan, TypeOfRefinancedOrRestructured) %>%
  distinct(ReportDate_NewLoan, LoanNumber_OldLoan, .keep_all = TRUE) %>%
  mutate(PotentialRestructured = "Yes",
         AdditionalNrRestr = if_else(TypeOfRefinancedOrRestructured %in% TypesOfRefiOrRestrNotToCount, 0, 1)) %>%
  right_join(LPData, by = c("LoanNumber_OldLoan" = "LoanNumber", "ReportDate_NewLoan" = "ReportDate")) %>%
  # Now we need to merge the PotentialRefinanced and TypeOfRefinancedOrRestructured info 
  mutate(PotentialRestructured = if_else( (PotentialRestructured.x == "Yes" & !is.na(PotentialRestructured.x)) |
                                            (PotentialRestructured.y == "Yes" & !is.na(PotentialRestructured.y)), 
                                          "Yes", "No"),
         TypeOfRefinancedOrRestructured = if_else(!is.na(TypeOfRefinancedOrRestructured.x),
                                                  TypeOfRefinancedOrRestructured.x, TypeOfRefinancedOrRestructured.y),
         AdditionalNrRestr = replace_na(AdditionalNrRestr, 0),
         NumberCalculatedRestructurings = pmax(NumberCalculatedRestructurings, AdditionalNrRestr)) %>%
  rename(ReportDate = ReportDate_NewLoan, LoanNumber = LoanNumber_OldLoan) %>%
  select(-c(PotentialRestructured.x, PotentialRestructured.y, AdditionalNrRestr, TypeOfRefinancedOrRestructured.x, TypeOfRefinancedOrRestructured.y))


# Find the principal amount in the previous month to see if it increased; if it did and the loan was in PAR, flag as potential refi/restr
LPData <- LPData %>%
  mutate(PrevMonth = ReportDate %m+% months(1)) %>%
  select(PrevMonth, LoanNumber, PrincipalCurrencyLoan, ArrearsDays) %>%
  right_join(LPData, by = c("LoanNumber" = "LoanNumber", "PrevMonth" = "ReportDate"),
             suffix = c("_PrevMonth", "")) %>% 
  rename(ReportDate = PrevMonth) %>%
  mutate(PrincipalCurrencyLoan_PrevMonth = replace_na(PrincipalCurrencyLoan_PrevMonth, 0),
         ArrearsDays_PrevMonth = replace_na(ArrearsDays_PrevMonth, 0),
         PotentialRefinanced = 
           # if the loan is a type where principal can change, set to No
           if_else(ProductType %in% LoanTypesWithChangingPrincipal, "No",
                   if_else(is.na(PrincipalCurrencyLoan_PrevMonth) | is.na(ArrearsDays_PrevMonth),
                           # loan didn't exist last month - keep current refinancing status
                           PotentialRefinanced,
                           if_else((PrincipalCurrencyLoan-1 > PrincipalCurrencyLoan_PrevMonth) & ArrearsDays_PrevMonth > 0,
                                   # principal increased and PAR was >0 (if it was PAR30, will be flagged as potential restructured, which takes presedence)
                                   "Yes", PotentialRefinanced))),
         PotentialRestructured = 
           # if the loan is a type where principal can change, set to No
           if_else(ProductType %in% LoanTypesWithChangingPrincipal, "No",
                   if_else(is.na(PrincipalCurrencyLoan_PrevMonth) | is.na(ArrearsDays_PrevMonth),
                           # loan didn't exist last month - keep current refinancing status
                           PotentialRestructured,
                           if_else((PrincipalCurrencyLoan-1 > PrincipalCurrencyLoan_PrevMonth) & ArrearsDays_PrevMonth > 30,
                                   # principal increased and PAR was >30 
                                   "Yes", PotentialRestructured))),
         # Set the reason for flagging
         TypeOfRefinancedOrRestructured =
           if_else(is.na(PrincipalCurrencyLoan_PrevMonth) | is.na(ArrearsDays_PrevMonth) | (ProductType %in% LoanTypesWithChangingPrincipal),
                   # loan didn't exist last month or the product type usually changes principal
                   TypeOfRefinancedOrRestructured,
                   if_else(PrincipalCurrencyLoan-1 <= PrincipalCurrencyLoan_PrevMonth,
                           # principal did not increase
                           TypeOfRefinancedOrRestructured,
                           if_else(ArrearsDays_PrevMonth > 30,
                                   factor(which(TypeOfRefinancedOrRestructuredLabels == "Principal increased in PAR30"),
                                          levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                          labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE),
                                   if_else(ArrearsDays_PrevMonth > 0,
                                           factor(which(TypeOfRefinancedOrRestructuredLabels == "Principal increased in PAR1-30"),
                                                  levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                  labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE),
                                           TypeOfRefinancedOrRestructured)))),
         # Add to the number of restructurings
         NumberCalculatedRestructurings = if_else(Restructured != "Yes" & Refinanced != "Yes" & 
                                                    !(ProductType %in% LoanTypesWithChangingPrincipal) &
                                                    !(TypeOfRefinancedOrRestructured %in% TypesOfRefiOrRestrNotToCount) &
                                                    (PrincipalCurrencyLoan-1 > PrincipalCurrencyLoan_PrevMonth) & 
                                                    ArrearsDays_PrevMonth > 0,
                                                  1, NumberCalculatedRestructurings)) %>%
  select(-c(PrincipalCurrencyLoan_PrevMonth, ArrearsDays_PrevMonth))



# Clean NumberCalculatedRestructurings 
LPData <- LPData %>% mutate(NumberCalculatedRestructurings = replace_na(NumberCalculatedRestructurings, 0))


# Set the NumberCalculatedRestructurings to 1 for loans reported as restructured or refinanced, the first time they are
# (we make a cumulation of the number of restructurings later)
LPData <- LPData %>%
  filter(Restructured == "Yes" | Refinanced == "Yes") %>%
  group_by(LoanNumber) %>%
  summarise(FirstReportDateOfRefi = min(ReportDate)) %>%
  mutate(AdditionalNrRestr = 1) %>%
  # select(-TypeOfRefinancedOrRestructured) %>%
  right_join(LPData, by = c("LoanNumber" = "LoanNumber", "FirstReportDateOfRefi" = "ReportDate")) %>%
  rename(ReportDate = FirstReportDateOfRefi) %>%
  mutate(AdditionalNrRestr = replace_na(AdditionalNrRestr, 0),
         # Don't count if Restructured/Refinanced shouldn't be counted as restructured
         AdditionalNrRestr = if_else( ("Reported as refinanced in past" %in% TypesOfRefiOrRestrNotToCount) & (Refinanced == "Yes"), 0,
                                      if_else( ("Reported as restructured in past" %in% TypesOfRefiOrRestrNotToCount) & (Restructured == "Yes"), 0,
                                               AdditionalNrRestr)),
         NumberCalculatedRestructurings = pmax(NumberCalculatedRestructurings, AdditionalNrRestr)) %>%
  select(-AdditionalNrRestr) %>% ungroup() 



# ---------------------------- Add a migration PAR bucket, which has more categories than the current PAR bucket

# Write offs
LPData$PARbucket[!is.na(LPData$WriteOffDate) & 
                   (floor_date(LPData$WriteOffDate, "month") == LPData$ReportDate)] <- "17 Written off"

# Group Restructured / potentially restructured and Refinanced / potentially refinanced into the one variable RefinancingStatus
# and remove the replaced variables
LPData <- LPData %>%
  mutate(RefinancingStatus = 
           if_else(Restructured == "Yes", "Restructured",
                   if_else(PotentialRestructured == "Yes", "Potential restructured",
                           if_else(Refinanced == "Yes", "Refinanced",
                                   if_else(PotentialRefinanced == "Yes", "Potential refinanced",
                                           "Not refinanced or restructured"))))) %>%
  select(-c(Restructured, PotentialRestructured, Refinanced, PotentialRefinanced))


# Set TypeOfRefinancedOrRestructured for loans reported as Restructured or Refinanced
LPData[LPData$RefinancingStatus == "Restructured", "TypeOfRefinancedOrRestructured"] <- "Reported as restructured in past"
LPData[LPData$RefinancingStatus == "Refinanced", "TypeOfRefinancedOrRestructured"] <- "Reported as refinanced in past"


# Moratorium or Grace Period if the loan is in moratorium or grace period
LPData$PARbucket[(LPData$MoratoriumStatus == "Yes") | 
                   (LPData$GracePeriodStatus == "Yes")] <- "01 Moratorium or Grace Period"


# Find loans that changed loan number and became labeled as restructured or refinanced
LPData <- ReplacedLoans %>%
  # select the loans that were replaced by a Restructured or Refinanced loan
  filter(Restructured == "Yes" | Refinanced == "Yes") %>%
  # Add a number of restructurings for these loans
  mutate(TypeOfRefinancedOrRestructured = factor("Reported as restructured in past", 
                                                 levels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE),
         AdditionalNrRestr = if_else(TypeOfRefinancedOrRestructured %in% TypesOfRefiOrRestrNotToCount, 0, 1)) %>%
  select(-c(ReportDate, ClientNumber, LoanNumber_NewLoan, TypeOfRefinancedOrRestructured)) %>%
  distinct(LoanNumber_OldLoan, NextMonth, .keep_all = TRUE) %>%
  # Add the Restructured/Refinanced info to LPData for the replaced loan, in the same month that the replacing loan appears
  right_join(LPData, by = c("LoanNumber_OldLoan" = "LoanNumber", "NextMonth" = "ReportDate")) %>%
  mutate(AdditionalNrRestr = replace_na(AdditionalNrRestr, 0),
         NumberCalculatedRestructurings = pmax(NumberCalculatedRestructurings, AdditionalNrRestr)) %>% 
  rename(LoanNumber = LoanNumber_OldLoan,
         ReportDate = NextMonth,
         ReplacedByRefinanced = Refinanced,
         ReplacedByRestructured = Restructured) %>%
  select(-AdditionalNrRestr) 


# Change RefinancingStatus and TypeOfRefinancedOrRestructured for the replaced loan
# First for refinanced
LPData[(LPData$ReplacedByRefinanced == "Yes" & !is.na(LPData$ReplacedByRefinanced)), c("RefinancingStatus", "TypeOfRefinancedOrRestructured")] <-
  data.frame(RefinancingStatus = rep("Restructured", sum(LPData$ReplacedByRefinanced == "Yes", na.rm = T)), 
             TypeOfRefinancedOrRestructured = rep("Replaced by refinanced loan", sum(LPData$ReplacedByRefinanced == "Yes", na.rm = T)),
             stringsAsFactors = FALSE)
# Then for restructured
LPData[(LPData$ReplacedByRestructured == "Yes" & !is.na(LPData$ReplacedByRestructured)), c("RefinancingStatus", "TypeOfRefinancedOrRestructured")] <-
  data.frame(RefinancingStatus = rep("Restructured", sum(LPData$ReplacedByRestructured == "Yes", na.rm = T)), 
             TypeOfRefinancedOrRestructured = rep("Replaced by restructured loan", sum(LPData$ReplacedByRestructured == "Yes", na.rm = T)),
             stringsAsFactors = FALSE)
# And change the number of restructurings. If the previous TypeOfRefi was one that should count, that count stays
LPData[(LPData$ReplacedByRefinanced == "Yes" & !is.na(LPData$ReplacedByRefinanced)) & !(LPData$TypeOfRefinancedOrRestructured %in% TypesOfRefiOrRestrNotToCount),
       "NumberCalculatedRestructurings"] <- 1
LPData[(LPData$ReplacedByRestructured == "Yes" & !is.na(LPData$ReplacedByRestructured)) & !(LPData$TypeOfRefinancedOrRestructured %in% TypesOfRefiOrRestrNotToCount), 
       "NumberCalculatedRestructurings"] <- 1



# Make sure loans loans that are restructured, refinanced, or written off remain such for all later dates
# Potentially refinanced: find when the loan was first Potentially refinanced
refi_table <- LPData %>%
  filter(RefinancingStatus == "Potential refinanced") %>%
  select(LoanNumber, ReportDate, TypeOfRefinancedOrRestructured) %>%
  group_by(LoanNumber, TypeOfRefinancedOrRestructured) %>%
  summarise(ReportDate_Restructured = min(ReportDate)) %>%
  rename(TypeOfRefinancedOrRestructured_refi_table = TypeOfRefinancedOrRestructured)
# Set the PotentialRefi_flag for all dates after the restructuring
LPData <- LPData %>%
  left_join(refi_table, by = "LoanNumber") %>%
  # if one loan has several flagging reasons, it will have several entries now - we now remove them
  filter(ReportDate >= ReportDate_Restructured, !is.na(ReportDate_Restructured)) %>%
  arrange(desc(ReportDate_Restructured)) %>%
  distinct(LoanNumber, ReportDate, .keep_all= TRUE) %>%
  select(LoanNumber, ReportDate, ReportDate_Restructured, TypeOfRefinancedOrRestructured_refi_table) %>%
  # join in with the full dataset
  right_join(LPData, by = c("LoanNumber" = "LoanNumber", "ReportDate" = "ReportDate")) %>%
  # flag loans when the reporting date is after the restructuring/refi date; keep the flags on TypeOfRefinancedOrRestructured that exist
  mutate(PotentialRefi_flag = (ReportDate >= ReportDate_Restructured),
         TypeOfRefinancedOrRestructured = if_else(PotentialRefi_flag & !is.na(TypeOfRefinancedOrRestructured_refi_table) & 
                                                    is.na(TypeOfRefinancedOrRestructured),
                                                  TypeOfRefinancedOrRestructured_refi_table, TypeOfRefinancedOrRestructured)) %>%
  select(-c(ReportDate_Restructured, TypeOfRefinancedOrRestructured_refi_table)) 

# Refinanced: find when the loan was first refinanced
refi_table <- LPData %>%
  filter(RefinancingStatus == "Refinanced") %>%
  select(LoanNumber, ReportDate) %>%
  group_by(LoanNumber) %>%
  summarise(ReportDate_Restructured = min(ReportDate)) %>%
  mutate(TypeOfRefinancedOrRestructured_refi_table = factor(which(TypeOfRefinancedOrRestructuredLabels == "Reported as refinanced in past"), 
                                                            levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                            labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE))
# Set the Refi_flag for all dates after the restructuring
LPData <- LPData %>%
  left_join(refi_table, by = "LoanNumber") %>%
  # if one loan has several flagging reasons, it will have several entries now - we now remove them
  filter(ReportDate >= ReportDate_Restructured, !is.na(ReportDate_Restructured)) %>%
  arrange(desc(ReportDate_Restructured)) %>%
  distinct(LoanNumber, ReportDate, .keep_all= TRUE) %>%
  select(LoanNumber, ReportDate, ReportDate_Restructured, TypeOfRefinancedOrRestructured_refi_table) %>%
  # join in with the full dataset
  right_join(LPData, by = c("LoanNumber" = "LoanNumber", "ReportDate" = "ReportDate")) %>%
  # flag loans when the reporting date is after the restructuring/refi date; keep the flags on TypeOfRefinancedOrRestructured that exist
  mutate(Refi_flag = (ReportDate >= ReportDate_Restructured),
         TypeOfRefinancedOrRestructured = if_else(Refi_flag & !is.na(TypeOfRefinancedOrRestructured_refi_table) & 
                                                    is.na(TypeOfRefinancedOrRestructured),
                                                  TypeOfRefinancedOrRestructured_refi_table, TypeOfRefinancedOrRestructured)) %>%
  select(-c(ReportDate_Restructured, TypeOfRefinancedOrRestructured_refi_table)) 

# Potentially restructured: find when the loan was first Potentially restructured
refi_table <- LPData %>%
  filter(RefinancingStatus == "Potential restructured") %>%
  select(LoanNumber, ReportDate, TypeOfRefinancedOrRestructured) %>%
  group_by(LoanNumber, TypeOfRefinancedOrRestructured) %>%
  summarise(ReportDate_Restructured = min(ReportDate)) %>%
  rename(TypeOfRefinancedOrRestructured_refi_table = TypeOfRefinancedOrRestructured)
# Set the PotentialRestr_flag for all dates after the restructuring
LPData <- LPData %>%
  left_join(refi_table, by = "LoanNumber") %>% 
  # if one loan has several flagging reasons, it will have several entries now - we now remove them
  filter(ReportDate >= ReportDate_Restructured, !is.na(ReportDate_Restructured)) %>%
  arrange(desc(ReportDate_Restructured)) %>%
  distinct(LoanNumber, ReportDate, .keep_all= TRUE) %>%
  select(LoanNumber, ReportDate, ReportDate_Restructured, TypeOfRefinancedOrRestructured_refi_table) %>%
  # join in with the full dataset
  right_join(LPData, by = c("LoanNumber" = "LoanNumber", "ReportDate" = "ReportDate")) %>%
  # flag loans when the reporting date is after the restructuring/refi date; keep the flags on TypeOfRefinancedOrRestructured that exist
  mutate(PotentialRestr_flag = (ReportDate >= ReportDate_Restructured),
         TypeOfRefinancedOrRestructured = if_else(PotentialRestr_flag & !is.na(TypeOfRefinancedOrRestructured_refi_table) 
                                                  & is.na(TypeOfRefinancedOrRestructured),
                                                  TypeOfRefinancedOrRestructured_refi_table, TypeOfRefinancedOrRestructured)) %>%
  select(-c(ReportDate_Restructured, TypeOfRefinancedOrRestructured_refi_table)) 

# Restructured: find when the loan was first restructured
refi_table <- LPData %>%
  filter(RefinancingStatus == "Restructured") %>%
  select(LoanNumber, ReportDate) %>%
  group_by(LoanNumber) %>%
  summarise(ReportDate_Restructured = min(ReportDate)) %>%
  mutate(TypeOfRefinancedOrRestructured_refi_table = factor(which(TypeOfRefinancedOrRestructuredLabels == "Reported as restructured in past"), 
                                                            levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                            labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE))
# Set the Restr_flag for all dates after the restructuring
LPData <- LPData %>%
  left_join(refi_table, by = "LoanNumber") %>%
  # if one loan has several flagging reasons, it will have several entries now - we now remove them
  filter(ReportDate >= ReportDate_Restructured, !is.na(ReportDate_Restructured)) %>%
  arrange(desc(ReportDate_Restructured)) %>%
  distinct(LoanNumber, ReportDate, .keep_all= TRUE) %>%
  select(LoanNumber, ReportDate, ReportDate_Restructured, TypeOfRefinancedOrRestructured_refi_table) %>%
  # join in with the full dataset
  right_join(LPData, by = c("LoanNumber" = "LoanNumber", "ReportDate" = "ReportDate")) %>%
  # flag loans when the reporting date is after the restructuring/refi date
  mutate(Restr_flag = (ReportDate >= ReportDate_Restructured),
         # Change TypeOfRefinancedOrRestructured only if it isn't already reported as restructured; keep the flags on TypeOfRefinancedOrRestructured that exist
         TypeOfRefinancedOrRestructured = if_else(Restr_flag & !is.na(TypeOfRefinancedOrRestructured_refi_table) & 
                                                    is.na(TypeOfRefinancedOrRestructured),
                                                  TypeOfRefinancedOrRestructured_refi_table, TypeOfRefinancedOrRestructured)) %>%
  select(-c(ReportDate_Restructured, TypeOfRefinancedOrRestructured_refi_table))

# Written off: find when the loan was first written off
refi_table <- LPData %>%
  filter(PARbucket == "17 Written off") %>%
  select(LoanNumber, ReportDate) %>% 
  group_by(LoanNumber) %>%
  summarise(ReportDate_WO = min(ReportDate)) %>%
  mutate(TypeOfRefinancedOrRestructured_refi_table = factor(which(TypeOfRefinancedOrRestructuredLabels == "Written off"), 
                                                            levels = as.character(1:length(TypeOfRefinancedOrRestructuredLabels)),
                                                            labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE))
# Set the WO_flag for all dates after the write off
LPData <- LPData %>%
  left_join(refi_table, by = "LoanNumber") %>%
  # if one loan has several flagging reasons, it will have several entries now - we now remove them
  filter(ReportDate >= ReportDate_WO, !is.na(ReportDate_WO)) %>%
  arrange(desc(ReportDate_WO)) %>%
  distinct(LoanNumber, ReportDate, .keep_all= TRUE) %>%
  select(LoanNumber, ReportDate, ReportDate_WO, TypeOfRefinancedOrRestructured_refi_table) %>%
  # join in with the full dataset
  right_join(LPData, by = c("LoanNumber" = "LoanNumber", "ReportDate" = "ReportDate")) %>%
  # flag loans when the reporting date is after the restructuring/refi date
  mutate(WO_flag = (ReportDate >= ReportDate_WO),
         TypeOfRefinancedOrRestructured = if_else(WO_flag & !is.na(TypeOfRefinancedOrRestructured_refi_table),
                                                  TypeOfRefinancedOrRestructured_refi_table, TypeOfRefinancedOrRestructured)) %>%
  select(-c(ReportDate_WO, TypeOfRefinancedOrRestructured_refi_table)) 

rm(refi_table)

# If the flag is NA, set it to FALSE
LPData[is.na(LPData$Restr_flag), "Restr_flag"] <- FALSE
LPData[is.na(LPData$PotentialRestr_flag), "PotentialRestr_flag"] <- FALSE
LPData[is.na(LPData$Refi_flag), "Refi_flag"] <- FALSE
LPData[is.na(LPData$PotentialRefi_flag), "PotentialRefi_flag"] <- FALSE
LPData[is.na(LPData$WO_flag), "WO_flag"] <- FALSE

# Add the flags into RefinancingStatus and remove the flags
LPData <- LPData %>%
  mutate(RefinancingStatus = if_else(Restr_flag, "Restructured",
                                     if_else(PotentialRestr_flag, "Potential restructured",
                                             if_else(Refi_flag, "Refinanced",
                                                     if_else(PotentialRefi_flag, "Potential refinanced",
                                                             "Not refinanced or restructured"))))) %>%
  select(-c(Restr_flag, PotentialRestr_flag, Refi_flag, PotentialRefi_flag))

# Do the same for written off loans
LPData <- LPData %>%
  mutate(PARbucket = if_else(WO_flag, 
                             factor(which(levels(LPData$PARbucket) == "17 Written off"),
                                    levels = PARbucketLevels,
                                    labels = PARbucketLabels, ordered = TRUE),
                             PARbucket)) %>% select(-WO_flag) 


# Fill the Number of Restructurings and the worst TypeOfRefinancedOrRestructured down from each date to all later dates (could probably use this approach for RefinancingStatus too)
# Select all report dates except the first one, since we need to look at the previous month
ReportDates <- unique(LPData$ReportDate)[order(unique(LPData$ReportDate))]
ReportDates <- ReportDates[2:length(ReportDates)]
for (d in ReportDates) {
  
  # For each date, find the flag of the previous date and assign it
  temp <- LPData %>%
    # make a table of only this report date
    filter(ReportDate == d) %>%
    mutate(ReportDate_prevMonth = ReportDate %m-% months(1)) %>%
    select(LoanNumber, ReportDate, ReportDate_prevMonth, TypeOfRefinancedOrRestructured, NumberCalculatedRestructurings) %>%
    left_join(select(LPData, LoanNumber, ReportDate, TypeOfRefinancedOrRestructured, NumberCalculatedRestructurings), 
              by = c("LoanNumber" = "LoanNumber", "ReportDate_prevMonth" = "ReportDate"),
              suffix = c("", "_prevMonth")) %>%
    mutate(NumberCalculatedRestructurings_prevMonth = replace_na(NumberCalculatedRestructurings_prevMonth, 0)) %>%
    select(-ReportDate_prevMonth)
  
  # Find the worst flagging reason 
  TypeOfRefinancedOrRestructured_table <- pmax(as.numeric(temp$TypeOfRefinancedOrRestructured), as.numeric(temp$TypeOfRefinancedOrRestructured_prevMonth), na.rm = TRUE) 
  dim(temp)
  dim(LPData[LPData$ReportDate == d,])
  # Add the worst flag back as the TypeOfRefinancedOrRestructured
  LPData[LPData$ReportDate == d, "TypeOfRefinancedOrRestructured"] <- factor(TypeOfRefinancedOrRestructured_table, 
                                                                             levels = as.character(c(1:length(TypeOfRefinancedOrRestructuredLabels))),
                                                                             labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE)
  # Sum up the number of restructurings 
  LPData[LPData$ReportDate == d, "NumberCalculatedRestructurings"] <- (temp$NumberCalculatedRestructurings + temp$NumberCalculatedRestructurings_prevMonth)
}
# Note that there might be many loans with the excluded Refi/Restr types; these have had a different refi/restr type before
rm(temp, TypeOfRefinancedOrRestructured_table)


# Save data in case something goes wrong in the next section
save.image(paste0(SaveLocation, "\\", "Section3.RData"))





####################################################################################################################################
# 4. Add repayment flag, based on how the loan's principal amount was reduced vs the expected principal repayments
####################################################################################################################################

# Define function to calculate the instalments
# The MIT License (MIT)
# Copyright (c) 2012 Schaun Jacob Wheeler (adjusted by Bea)
amortize <- function(DisbAmt, IntRate, MaturityLengthInMonths, output = "table", LoanIdentifier = NULL) { 
  
  if(is.null(LoanIdentifier)) {
    LoanIdentifier <- matrix(rep(1:length(MaturityLengthInMonths), each = MaturityLengthInMonths[1]), 
                             nrow = MaturityLengthInMonths[1])
  } else {
    LoanIdentifier <- matrix(rep(LoanIdentifier, each = (max(MaturityLengthInMonths)+GracePeriodInMonths)), 
                             nrow = (max(MaturityLengthInMonths)+GracePeriodInMonths))
  }
  
  DisbAmt <- matrix(DisbAmt, ncol = length(DisbAmt))
  IntRate <- matrix(IntRate, ncol = length(IntRate))
  IntRate_monthly <- IntRate / (12)
  payment <- DisbAmt * IntRate_monthly / (1 - (1 + IntRate_monthly)^(-MaturityLengthInMonths))
  
  Pt <- DisbAmt # current principal or amount of loan
  currP <- NULL
  
  for(i in 1:max(MaturityLengthInMonths)) {
    H <- Pt * IntRate_monthly # current monthly interest
    C <- payment - H # monthly payment minus monthly interest (principal paid for each month)
    Q <- Pt - C # new balance of principal of loan
    Pt <- Q # loops for max number of months
    currP <- rbind(currP, Pt)    
  }
  
  # Add the disbursement amount for the number of months of grace period
  GracePeriod_outstanding <- DisbAmt
  for (i in 1:GracePeriodInMonths) { 
    GracePeriod_outstanding <- rbind(GracePeriod_outstanding, DisbAmt) 
  }
  
  principal_outstanding <- rbind(GracePeriod_outstanding, currP[1:(max(MaturityLengthInMonths)-1),, drop = FALSE])
  currP <- rbind(GracePeriod_outstanding[1:GracePeriodInMonths,], currP)
  monthly_principal <- principal_outstanding - currP
  monthly_interest <- rbind(
    (
      # Make a payment matrix where the first rows are zeros during the grace period, and thereafter the instalments
      (rbind(matrix(rep(0, dim(payment)[2]*GracePeriodInMonths), nrow = GracePeriodInMonths), 
             matrix(
               rep(payment, max(MaturityLengthInMonths)), 
               nrow = max(MaturityLengthInMonths), 
               # Deduct principal part to get interest
               byrow = TRUE))) - monthly_principal)[1:(max(MaturityLengthInMonths+GracePeriodInMonths)-1),, drop = FALSE],
    rep(0, length(MaturityLengthInMonths)))
  
  installment_number <- matrix(rep(1 : (max(MaturityLengthInMonths)+GracePeriodInMonths), 
                                   length(MaturityLengthInMonths)), 
                               nrow = (max(MaturityLengthInMonths)+GracePeriodInMonths))
  
  # remove entries where principal is small
  monthly_interest[principal_outstanding < 1] <- 0
  monthly_principal[principal_outstanding < 1] <- 0
  principal_outstanding[principal_outstanding < 1] <- 0
  
  monthly_payment <- monthly_principal + monthly_interest
  input <- list(
    "LoanIdentifier" = LoanIdentifier,
    "InstalmentNumber" = installment_number,
    "PrincipalOutstandingExpected" = principal_outstanding,
    # "Instalment" = monthly_payment,
    "PrincipalPaymentExpected" = monthly_principal,
    "InterestPaymentExpected" = monthly_interest
  )
  
  out <- switch(output, 
                "list" = input,
                "table" = as.data.frame(
                  lapply(input, as.vector), 
                  stringsAsFactors = FALSE),
                "PrincipalOutstandingExpected" = as.data.frame(
                  lapply(input[c("LoanIdentifier", "PrincipalOutstandingExpected")], as.vector),
                  stringsAsFactors = FALSE),
                # "Instalment" = as.data.frame(
                #   lapply(input[c("LoanIdentifier", "Instalment")], as.vector), 
                #   stringsAsFactors = FALSE),
                "PrincipalPaymentExpected" = as.data.frame(
                  lapply(input[c("LoanIdentifier", "PrincipalPaymentExpected")], as.vector), 
                  stringsAsFactors = FALSE), 
                "InterestPaymentExpected" = as.data.frame(
                  lapply(input[c("LoanIdentifier", "InterestPaymentExpected")], as.vector), 
                  stringsAsFactors = FALSE)
  )
  out
}


# Select only necessary columns to create repaymentData
repaymentData <- LPData %>%
  select(ReportDate, LoanNumber, DisbursementDate, DisbursedAmountCurrencyLoan,
         ContractualMaturityDate, YearlyNominalIR, 
         PrincipalCurrencyLoan, AccruedIRCurrencyLoan)


# First create table repaymentData with only ending LPs (i.e. all except the first ones determined by LookbackInMonths) 
AllReportDates <- unique(repaymentData$ReportDate)[order(unique(repaymentData$ReportDate))]


# Then add each other month to the last LPs 
# Add one at a time to get them in order
# Format as character
datesAsMonth <- format(as.Date(AllReportDates), "%Y%m")
# Need them to be the end of each month
ReportDatesEndMonth <- AllReportDates %m+% months(1) %m-% days(1)

# Loop through the last report dates
for (i in 1:LookbackInMonths) {
  repaymentData <- 
    repaymentData %>% 
    # take the previous months we need
    mutate(PrevMonth = ReportDate %m-% months(i)) %>%
    # add the Principal for that date
    left_join(select(LPData, ReportDate, LoanNumber, PrincipalCurrencyLoan),
              by = c("LoanNumber" = "LoanNumber", "PrevMonth" = "ReportDate"),
              suffix = c("", paste0("_PrevMonth_", i))) %>%
    select(-PrevMonth) 
}

# Rename the current Principal to make looping possible
repaymentData <- repaymentData %>% rename(PrincipalCurrencyLoan_PrevMonth_0 = PrincipalCurrencyLoan)

# Set NAs in principal outstanding to zero
# Look to see which columns are first and last
from = which(colnames(repaymentData) == "PrincipalCurrencyLoan_PrevMonth_1")
to = which(colnames(repaymentData) == paste0("PrincipalCurrencyLoan_PrevMonth_", LookbackInMonths))
# Set NAs to zero
for (i in from:to) { repaymentData[is.na(repaymentData[, i]), i] <- 0 }

# Now calculate repayments in each month, adding new columns for each month
for (i in 1:LookbackInMonths){
  # Calculate principal repayments
  repaymentData[, paste0("RepaidPrincipalCurrLoan_", i)] <-
    (repaymentData[, paste0("PrincipalCurrencyLoan_PrevMonth_", i)] 
     - repaymentData[, paste0("PrincipalCurrencyLoan_PrevMonth_", i-1)])
}

repaymentData <- data.table(repaymentData)



# -------------------- Calculate total payments by loan

# Repaid principal: unpivot columns and remove payments that happened before a loan's disbursement date
repaidPrinc <- repaymentData %>%
  select(LoanNumber, DisbursementDate, ReportDate, 
         RepaidPrincipalCurrLoan_1:!!paste0("RepaidPrincipalCurrLoan_", LookbackInMonths) ) %>%
  gather(key = "PaymentMonth", value = "RepaidPrinc", -c(LoanNumber, DisbursementDate, ReportDate)) %>%
  separate(PaymentMonth, c("NA1", "PaymentMonth"), sep = "_") %>%
  select(-NA1) %>%
  # Calculate the month of payment, and find the last of that month
  mutate(PaymentMonth = ReportDate %m-% months(as.numeric(PaymentMonth)-1) %m-% days(1)) %>%
  # remove payments before disbursement and before the first report date
  filter(DisbursementDate <= PaymentMonth,
         PaymentMonth >= (min(ReportDate) %m+% months(1))) %>%
  select(-DisbursementDate) %>%
  data.table()

# Remove negative repayments; these are disbursements / increases
repaidPrinc[(repaidPrinc$RepaidPrinc < 0 ), "RepaidPrinc"] <- 0

# Calculate total principal repaid for each loan
repaidPrinc <- repaidPrinc %>%
  group_by(LoanNumber, ReportDate) %>%
  summarise(TotalPrincipalRepaidCurrencyLoan = sum(RepaidPrinc, na.rm = T)) %>%
  ungroup()

# Add the payment information to the repaymentData to get all info we need
repaymentData <- repaymentData %>%
  # add the repayment information
  left_join(repaidPrinc,
            by = c("LoanNumber" = "LoanNumber", "ReportDate" = "ReportDate"))

# select only unique loans to calculate amortization plan for
DistinctLoans <- repaymentData %>%
  # the same loan number could have different maturities etc, so make an LoanIdentifier of the items we want to calculate separate payment plans for
  # we round the numbers, since there could be imprecisions otherwise
  mutate(LoanIdentifier = paste0(LoanNumber, round(DisbursedAmountCurrencyLoan, 2), format(DisbursementDate, "%Y%m%d"),
                                 round(YearlyNominalIR, 6), format(ContractualMaturityDate, "%Y%m%d"))) %>%
  distinct(LoanIdentifier, .keep_all = TRUE) %>%
  data.table()


# Calculate expected principal payments (can take a while)
amorttable <- amortize(
  DisbAmt = DistinctLoans$DisbursedAmountCurrencyLoan,
  IntRate = DistinctLoans$YearlyNominalIR,
  # Use the end of the grace period as disbursement date
  MaturityLengthInMonths = interval(DistinctLoans$DisbursementDate %m+% months(GracePeriodInMonths), DistinctLoans$ContractualMaturityDate) %/% months(1),
  output = "table",
  LoanIdentifier = DistinctLoans$LoanIdentifier)


# Shorten the table before we bring it in to the main dataset; it can be big
amorttable <- amorttable %>%
  filter(PrincipalOutstandingExpected > 0) %>% 
  left_join(select(DistinctLoans, LoanIdentifier, DisbursementDate), by = "LoanIdentifier") %>%
  mutate(InstalmentMonth = DisbursementDate %m+% months(InstalmentNumber)) %>% 
  select(-InstalmentNumber) %>%
  filter(InstalmentMonth >= AllReportDates[1], InstalmentMonth <= ReportDatesEndMonth[length(ReportDatesEndMonth)]) %>%
  select(-c(DisbursementDate)) %>%
  data.table()

# Add the date of instalment month and shorten what's possible
amorttable <- repaymentData %>%  
  # create the LoanIdentifier
  mutate(LoanIdentifier = paste0(LoanNumber, round(DisbursedAmountCurrencyLoan, 2), format(DisbursementDate, "%Y%m%d"),
                                 round(YearlyNominalIR, 6), format(ContractualMaturityDate, "%Y%m%d"))) %>%
  select(LoanIdentifier, ReportDate, LoanNumber) %>%
  left_join(amorttable, by = "LoanIdentifier") %>%
  select(-LoanIdentifier) %>%
  # Remove instalments outside of the reporting period
  filter(InstalmentMonth >= ReportDate %m-% months(LookbackInMonths),
         InstalmentMonth <= ReportDate %m+% months(1) %m-% days(1),
         # also cut everything before the reporting period
         InstalmentMonth > ReportDatesEndMonth[1]) %>%
  data.table()

# Calculate total expected payments for the last months
amorttableTotals <- amorttable %>% 
  group_by(LoanNumber, ReportDate) %>%
  summarise(TotalPrincPaymentsExpectedCurrencyLoan = sum(PrincipalPaymentExpected, na.rm = T)) %>%
  ungroup() 


# Add the expected payments to the actual ones
repaymentData <- repaymentData %>%
  # remove the columns we don't need
  select(-c(RepaidPrincipalCurrLoan_1:!!paste0("RepaidPrincipalCurrLoan_", LookbackInMonths),
            PrincipalCurrencyLoan_PrevMonth_1:!!paste0("PrincipalCurrencyLoan_PrevMonth_", LookbackInMonths))) %>% 
  # rename the Principal columns
  rename(PrincipalCurrencyLoan = PrincipalCurrencyLoan_PrevMonth_0) %>%
  # Add the Total expected payments
  left_join(amorttableTotals, by = c("LoanNumber" = "LoanNumber", "ReportDate" = "ReportDate")) %>%
  # Set NAs to zero; they come up when the disbursement date is in the previous month from the report date
  mutate(TotalPrincPaymentsExpectedCurrencyLoan = replace_na(TotalPrincPaymentsExpectedCurrencyLoan, 0),
         TotalPrincipalRepaidCurrencyLoan = replace_na(TotalPrincipalRepaidCurrencyLoan, 0)) %>%
  # calculate % paid of expected
  mutate(PrincipalPaidOfExpected = if_else(TotalPrincPaymentsExpectedCurrencyLoan > 0,
                                           TotalPrincipalRepaidCurrencyLoan / TotalPrincPaymentsExpectedCurrencyLoan, 1))
# Note that if the maturity date < report date, the TotalPrincPaymentsExpectedCurrencyLoan is Infinite and the PrincipalPaidOfExpected is always zero


# Now add the expected principal outstanding and the interest payments of the report date
repaymentData <- amorttable %>%
  # Now we only need data for the ReportDate
  filter(ReportDate == floor_date(InstalmentMonth, "month")) %>% 
  select(ReportDate, LoanNumber, PrincipalOutstandingExpected, PrincipalPaymentExpected, InterestPaymentExpected) %>%
  right_join(repaymentData, by = c("LoanNumber" = "LoanNumber", "ReportDate" = "ReportDate")) %>% 
  # Replace NAs with zeroes; amorttable is shorter than repaymentData due to 1) YearlyNominalIR of zero; 2) DisbursementDate in the reporting month; 3) ContractualMaturityDate in the past
  mutate(InterestPaymentExpected = replace_na(InterestPaymentExpected, 0),
         PrincipalPaymentExpected = replace_na(PrincipalPaymentExpected, 0),
         PrincipalOutstandingExpected = replace_na(PrincipalOutstandingExpected, 0)) %>% 
  # Calculate how many months of accrued interest is outstanding
  mutate(MonthsAccruedInterestOutstanding = AccruedIRCurrencyLoan / InterestPaymentExpected,
         # Calculate how many months of too high principal is outstanding. 1 means all is good
         MonthsTooHighPrincipalOutstanding = (PrincipalCurrencyLoan - PrincipalOutstandingExpected)/PrincipalPaymentExpected)


# Make them into buckets
repaymentData <- repaymentData %>%
  mutate(
    # What %-age of principal part of instalment was paid
    PrincipalPaidBucket = 
      # capped at a 100%; over that, all is well
      factor(
        if_else(is.na(YearlyNominalIR) | YearlyNominalIR < 0.001, "Interest rate is near zero",
                if_else(ReportDate %m-% months(LookbackInMonths) < min(ReportDate), "NA",
                        if_else( (PrincipalPaidOfExpected < CutOffForRepaidOfExpected) & (DisbursementDate < ReportDate),
                                 paste0("< ", CutOffForRepaidOfExpected*100, "% of expected was paid"),
                                 paste0(">= ", CutOffForRepaidOfExpected*100, "% of expected was paid"))))),
    # How many months' worth of accrued interest is currently outstanding, using the last expected interest payment as measure
    MonthsAccruedInterestBucket  =
      factor(
        if_else(is.na(YearlyNominalIR) | YearlyNominalIR < 0.001, "Interest rate is near zero",
                if_else(InterestPaymentExpected == 0 & 
                          AccruedIRCurrencyLoan > AmountOutstandingThatIsConsideredRepaid &
                          DisbursementDate < ReportDate, 
                        "Loan should have been repaid",
                        if_else(is.nan(MonthsAccruedInterestOutstanding) |
                                  MonthsAccruedInterestOutstanding <= CutOffForMonthsOfTooHighOutstanding |
                                  DisbursementDate >= ReportDate, 
                                paste0("0-", CutOffForMonthsOfTooHighOutstanding, " months of accrued interest outstanding"),
                                paste0(">", CutOffForMonthsOfTooHighOutstanding, " months of accrued interest outstanding"))))),
    # If the principal outstanding is higher than expected: How many months' worth of too high is it? Using the last expected principal payment as measure
    PrincipalOutstandingBucket = 
      factor(
        if_else(is.na(YearlyNominalIR) | YearlyNominalIR < 0.001, "Interest rate is near zero",
                if_else(PrincipalPaymentExpected == 0 & 
                          PrincipalCurrencyLoan > AmountOutstandingThatIsConsideredRepaid &
                          DisbursementDate < ReportDate, 
                        "Loan should have been repaid",
                        if_else(MonthsTooHighPrincipalOutstanding <= CutOffForMonthsOfTooHighOutstanding |
                                  DisbursementDate >= ReportDate |
                                  ContractualMaturityDate < ReportDate %m+% months(1), 
                                paste0("0-", CutOffForMonthsOfTooHighOutstanding, " months of principal above expected outstanding"),
                                paste0(">", CutOffForMonthsOfTooHighOutstanding, " months of principal above expected outstanding")))))) 


# Add these flags to LPData
LPData <- LPData %>%
  left_join(select(repaymentData, LoanNumber, ReportDate, PrincipalPaidBucket, MonthsAccruedInterestBucket, PrincipalOutstandingBucket, 
                   PrincipalPaidOfExpected, MonthsAccruedInterestOutstanding, MonthsTooHighPrincipalOutstanding),
            by = c("LoanNumber" = "LoanNumber", "ReportDate" = "ReportDate"))



# Clean up
rm(amorttable, amorttableTotals, DistinctLoans)


# Save data in case something goes wrong in the next section
save.image(paste0(SaveLocation, "\\", "Section4.RData"))



####################################################################################################################################
# 5. Add the next month status of PAR, refinancing status etc.
####################################################################################################################################


# Add the next month status to this month
NextMonthLP <- LPData %>%
  filter(ReportDate > min(ReportDate)) %>%
  mutate(
    nextMonth = ReportDate %m-% months(1)) %>%
  select(LoanNumber, PARbucket, RefinancingStatus, PrincipalCurrencyLoan, 
         TotalExposure, CashCollateral, nextMonth, ContractualMaturityDate, 
         YearlyNominalIR, TypeOfRefinancedOrRestructured, ReportedRestructuring, 
         NumberRestructurings, NumberCalculatedRestructurings,
         PrincipalPaidBucket, MonthsAccruedInterestBucket, PrincipalOutstandingBucket, RegulatorRiskClassification) 

# Join next month's PAR data into this month, to create migrationData
migrationData <- LPData %>%
  left_join(NextMonthLP,
            by = c("LoanNumber" = "LoanNumber", "ReportDate" = "nextMonth"),
            suffix = c("", "_nextMonth"))


# Add PAR buckets and flags that require comparing the two months

# Add the previous month status to find Moratorium and Grace and  Changed status with Savings
migrationData <- LPData %>%
  select(ReportDate, LoanNumber, PARbucket, PrincipalCurrencyLoan, CashCollateral) %>%
  mutate(ReportDate = ReportDate %m+% months(1)) %>%
  right_join(migrationData, by = c("ReportDate" = "ReportDate", "LoanNumber" = "LoanNumber"),
             suffix = c("_prevMonth", ""))


# Changed status using savings until next month: if the loan is not in arrears and in the next month: 
# the loan exists and has compulsory savings >= 0 and the compulsory savings are lower in this month than last month
migrationData <- migrationData %>%
  mutate(ChangedStatusUsingSavings_nextMonth = 
           # If the loan doesn't exist next month, set it to Not existing
           if_else(is.na(PrincipalCurrencyLoan_nextMonth), "Not existing", 
                   if_else(
                     # If cash collateral either doesn't exists or the balance didn't fall until next month: savings were not used
                     is.na(CashCollateral) | (CashCollateral == 0) | (!is.na(CashCollateral_nextMonth) & (CashCollateral <= CashCollateral_nextMonth)),
                     "Did not change status using savings",
                     if_else(
                       # If fully repaid: set to Repaid using savings
                       (PrincipalCurrencyLoan > 0) & (PARbucket_nextMonth == "00 Repaid" | is.na(PARbucket_nextMonth)), "Repaid using savings",
                       # Otherwise, if the PAR status was improved: Changed PAR status using savings
                       if_else(
                         as.numeric(PARbucket_nextMonth) < as.numeric(PARbucket), "Improved status using savings",
                         # Otherwise, savings were used, but the status didn't change
                         "Did not change status using savings"))))) %>%
  # change to factors
  mutate_at(vars(ChangedStatusUsingSavings_nextMonth), funs(factor))



# Same for this month, using previous month info
migrationData <- migrationData %>%
  mutate(ChangedStatusUsingSavings = 
           # If the loan didn't exist previous month, set it to New loan
           if_else(is.na(PrincipalCurrencyLoan_prevMonth), "New loan", 
                   if_else(
                     # If cash collateral either doesn't exists or the balance didn't fall from previous month: savings were not used
                     is.na(CashCollateral) | (CashCollateral == 0) | (!is.na(CashCollateral_prevMonth) & (CashCollateral_prevMonth <= CashCollateral)),
                     "Did not change status using savings",
                     if_else(
                       # If fully repaid: set to Repaid using savings
                       (PrincipalCurrencyLoan_prevMonth > 0) & (PARbucket == "00 Repaid"), "Repaid using savings",
                       # Otherwise, if the PAR status was improved: Changed PAR status using savings
                       if_else(
                         as.numeric(PARbucket) < as.numeric(PARbucket_prevMonth), "Improved status using savings",
                         # Otherwise, savings were used, but the status didn't change
                         "Did not change status using savings"))))) %>%
  # change to factors
  mutate_at(vars(ChangedStatusUsingSavings), funs(factor))



# Moratorium or Grace Period for next month if the loan is not in arrears and in the next month: the loan exists and is not in arrears and 
# the principal is the same as this month, but it's larger than close to zero (i.e. not repaid)
migrationData[(migrationData$PARbucket == "02 No arrears" | migrationData$PARbucket == "01 Moratorium or Grace Period") &
                (!is.na(migrationData$PARbucket_nextMonth) &
                   (migrationData$PARbucket_nextMonth == "02 No arrears")) &
                (migrationData$PrincipalCurrencyLoan == migrationData$PrincipalCurrencyLoan_nextMonth) &
                (migrationData$PrincipalCurrencyLoan_nextMonth > AmountOutstandingThatIsConsideredRepaid), 
              "PARbucket_nextMonth"] <- "01 Moratorium or Grace Period"

# Moratorium or Grace Period for current month: same but using previous month info
migrationData[(migrationData$PARbucket == "02 No arrears" | migrationData$PARbucket == "01 Moratorium or Grace Period") &
                (!is.na(migrationData$PARbucket_prevMonth) &
                   (migrationData$PARbucket_prevMonth == "02 No arrears" | migrationData$PARbucket_prevMonth == "01 Moratorium or Grace Period")) &
                (!is.na(migrationData$PrincipalCurrencyLoan_prevMonth) &
                   migrationData$PrincipalCurrencyLoan == migrationData$PrincipalCurrencyLoan_prevMonth) &
                (migrationData$PrincipalCurrencyLoan > AmountOutstandingThatIsConsideredRepaid), 
              "PARbucket"] <- "01 Moratorium or Grace Period"

# Remove info about previous month that we don't need
migrationData <- migrationData %>% select(-c(PARbucket_prevMonth, CashCollateral_prevMonth, PrincipalCurrencyLoan_prevMonth))


# Repaid if the loan doesn't exist next month (written off comes later)
migrationData[is.na(migrationData$PARbucket_nextMonth), 
              "PARbucket_nextMonth"] <- "00 Repaid"



# Find loans that changed loan numbers and became Restructured/Refinanced/Hidden refinanced/Hidden Restructured
# Hidden refinanced: add LoanNumber_NewLoan for these loans
migrationData <- HiddenRefinanced %>%
  # the old loan report date was the month before
  mutate(ReportDate_OldLoan = ReportDate_NewLoan %m-% months(1)) %>%
  select(ReportDate_OldLoan, LoanNumber_OldLoan, LoanNumber_NewLoan) %>%
  distinct(LoanNumber_OldLoan, ReportDate_OldLoan, .keep_all= TRUE) %>%
  # add the New Loan number to loans that became refinanced
  right_join(migrationData,
             by = c("LoanNumber_OldLoan" = "LoanNumber", "ReportDate_OldLoan" = "ReportDate")) %>%
  rename(ReportDate = ReportDate_OldLoan, LoanNumber = LoanNumber_OldLoan)


# Hidden restructured: add the LoanNumber_NewLoan_PotentialRestructured and LoanNumber_NewLoan_PotentialRefinanced to the data, 
# including only potential restructured / refinanced
migrationData <- HiddenRestructured %>%
  # the old loan report date was the month before
  mutate(ReportDate_OldLoan = ReportDate_NewLoan %m-% months(1)) %>%
  select(ReportDate_OldLoan, LoanNumber_OldLoan, LoanNumber_NewLoan) %>%
  distinct(LoanNumber_OldLoan, ReportDate_OldLoan, .keep_all= TRUE) %>%
  # add the New Loan number to loans that became restructured
  right_join(migrationData,
             by = c("LoanNumber_OldLoan" = "LoanNumber", "ReportDate_OldLoan" = "ReportDate"),
             suffix = c("_PotentialRestructured", "_PotentialRefinanced")) %>%
  rename(ReportDate = ReportDate_OldLoan, LoanNumber = LoanNumber_OldLoan)


# Restructured or refinanced; both get LoanNumber_NewLoan
migrationData <- ReplacedLoans %>%
  filter(Restructured == "Yes" | Refinanced == "Yes") %>%
  select(-c(NextMonth, ClientNumber)) %>%
  # An old loan might have several new loan numbers and therefore several new entries
  distinct(LoanNumber_OldLoan, ReportDate, .keep_all= TRUE) %>% 
  right_join(migrationData, by = c("LoanNumber_OldLoan" = "LoanNumber", "ReportDate" = "ReportDate"),
             suffix = c("_NextMonth", "")) %>%
  rename(LoanNumber = LoanNumber_OldLoan,
         Refinanced_NextMonth = Refinanced,
         Restructured_NextMonth = Restructured)


# Change refinancing status for the loans that changed loan number
# Potential refinanced
migrationData[!is.na(migrationData$LoanNumber_NewLoan_PotentialRefinanced), 
              "RefinancingStatus_nextMonth"] <- "Potential refinanced"
# Refinanced
migrationData[migrationData$Refinanced_NextMonth == "Yes" & !is.na(migrationData$Refinanced_NextMonth), 
              "RefinancingStatus_nextMonth"] <- "Refinanced"
# Potential restructured
migrationData[is.na(migrationData$Restructured_NextMonth) &
                !is.na(migrationData$LoanNumber_NewLoan_PotentialRestructured) |
                (!is.na(migrationData$RefinancingStatus_nextMonth) & migrationData$RefinancingStatus_nextMonth == "Potential restructured"), 
              "RefinancingStatus_nextMonth"] <- "Potential restructured"
# Restructured
migrationData[migrationData$Restructured_NextMonth == "Yes" & !is.na(migrationData$Restructured_NextMonth), 
              "RefinancingStatus_nextMonth"] <- "Restructured"


# Merge all types of LoanNumber_NewLoan into LoanNumber_NewLoan; Refinanced and Restructured loans already have that
# Potential refinanced
migrationData[!is.na(migrationData$LoanNumber_NewLoan_PotentialRefinanced) & 
                migrationData$RefinancingStatus_nextMonth == "Potential refinanced", 
              "LoanNumber_NewLoan"] <- migrationData[!is.na(migrationData$LoanNumber_NewLoan_PotentialRefinanced) & 
                                                       migrationData$RefinancingStatus_nextMonth == "Potential refinanced", 
                                                     "LoanNumber_NewLoan_PotentialRefinanced"]
# Potential restructured
migrationData[!is.na(migrationData$LoanNumber_NewLoan_PotentialRestructured) & 
                migrationData$RefinancingStatus_nextMonth == "Potential restructured", 
              "LoanNumber_NewLoan"] <- migrationData[!is.na(migrationData$LoanNumber_NewLoan_PotentialRestructured) & 
                                                       migrationData$RefinancingStatus_nextMonth == "Potential restructured", 
                                                     "LoanNumber_NewLoan_PotentialRestructured"]
# Remove LoanNumber_NewLoan_PotentialRefinanced and LoanNumber_NewLoan_PotentialRestructured
migrationData <- migrationData %>% select(-c(LoanNumber_NewLoan_PotentialRefinanced, LoanNumber_NewLoan_PotentialRestructured))


# Add a number of restructurings too; only necessary for Restructured and Refinanced
migrationData <- migrationData %>%
  mutate(
    # if the loan doesn't exist next month, keep the old number of restructurings
    NumberCalculatedRestructurings_nextMonth = if_else(is.na(NumberCalculatedRestructurings_nextMonth), 
                                                       NumberCalculatedRestructurings, NumberCalculatedRestructurings_nextMonth),
    # if the loan has a new loan number next month and the number of restructurings isn't higher, increase it
    NumberCalculatedRestructurings_nextMonth = if_else(!is.na(LoanNumber_NewLoan) &
                                                         !(TypeOfRefinancedOrRestructured %in% TypesOfRefiOrRestrNotToCount) &
                                                         (RefinancingStatus_nextMonth == "Restructured" | RefinancingStatus_nextMonth == "Refinanced") &
                                                         (NumberCalculatedRestructurings_nextMonth <= NumberCalculatedRestructurings),
                                                       NumberCalculatedRestructurings_nextMonth + 1, NumberCalculatedRestructurings_nextMonth))



# Find the TypeOfRefinancedOrRestructured for the new loan: TypeOfRefinancedOrRestructured_RefiLoan
migrationData <- migrationData %>%
  select(-c(Refinanced_NextMonth, Refinanced_NextMonth)) %>%
  mutate(ReportDate_nextMonth = ReportDate %m+% months(1)) %>%
  # Add the TypeOfRefinancedOrRestructured for the replacing loan, TypeOfRefinancedOrRestructured_RefiLoan
  left_join(select(migrationData, LoanNumber, ReportDate, TypeOfRefinancedOrRestructured),
            by = c("LoanNumber_NewLoan" = "LoanNumber", "ReportDate_nextMonth" = "ReportDate"),
            suffix = c("", "_RefiLoan"))

# Set TypeOfRefinancedOrRestructured to Reported as restructured or refinanced if it was reported as such, unless we found a worse label
migrationData$TypeOfRefinancedOrRestructured[migrationData$ReportedRestructuring == "Refinanced" &
                                               as.numeric(migrationData$TypeOfRefinancedOrRestructured) <= which(TypeOfRefinancedOrRestructuredLabels == "Reported as refinanced")] <- factor("Reported as refinanced")
migrationData$TypeOfRefinancedOrRestructured[migrationData$ReportedRestructuring == "Restructured" &
                                               as.numeric(migrationData$TypeOfRefinancedOrRestructured) <= which(TypeOfRefinancedOrRestructuredLabels == "Reported as restructured")] <- factor("Reported as restructured")


# Set RefinancingStatus to Restructured only if they were reported as such, otherwise set to Potential
migrationData$RefinancingStatus[migrationData$RefinancingStatus == "Restructured" &
                                  migrationData$ReportedRestructuring != "Restructured"] <- "Potential restructured"
migrationData$RefinancingStatus[migrationData$RefinancingStatus == "Refinanced" &
                                  migrationData$ReportedRestructuring != "Refinanced"] <- "Potential refinanced"




# Choose the TypeOfRefinancedOrRestructured for next month of the refinanced loan if it is worse than the current flagging reason
# Find the worst flagging reason
migrationData$TypeOfRefinancedOrRestructured_nextMonth <- factor(
  pmax(as.numeric(migrationData$TypeOfRefinancedOrRestructured_nextMonth), as.numeric(migrationData$TypeOfRefinancedOrRestructured_RefiLoan), na.rm = TRUE),
  levels = as.character(c(1:length(TypeOfRefinancedOrRestructuredLabels))),
  labels = TypeOfRefinancedOrRestructuredLabels, ordered = TRUE)

# Remove unnecessary flag
migrationData <- migrationData %>% select(-TypeOfRefinancedOrRestructured_RefiLoan)

# Add the new (restructured/refinanced with new Loan numbers) loan's PAR status as the PARbucket_nextMonth to the old loan
# If there are several new loans, take the worst PAR status (could use this approach for RefinancingStatus & Flagging too)
migrationData <- migrationData %>% 
  # choose loans that will get a new number next month 
  filter(!is.na(LoanNumber_NewLoan)) %>%
  # the new loan report date is the month after
  mutate(ReportDate_NewLoan = ReportDate %m+% months(1)) %>%
  select(ReportDate_NewLoan, LoanNumber, LoanNumber_NewLoan) %>%
  # find the PARbucket in the next month
  left_join(select(migrationData, ReportDate, LoanNumber, PARbucket), 
            by = c("ReportDate_NewLoan" = "ReportDate", "LoanNumber_NewLoan" = "LoanNumber")) %>%
  # one old loan might have several new loans, so we need to take the worst PAR bucket for each old loan
  group_by(LoanNumber, ReportDate_NewLoan) %>%
  # Assign the worst PARbucket
  summarise(PARbucket_nextMonth_refi = max(as.numeric(PARbucket))) %>%
  # the new loan report date was the month after
  mutate(ReportDate = ReportDate_NewLoan %m-% months(1)) %>%
  # add this to the main dataset
  right_join(migrationData, 
             by = c("ReportDate" = "ReportDate", "LoanNumber" = "LoanNumber")) %>%
  # if the loan has a refinanced PAR bucket, use that as PARbucket_nextMonth
  mutate(PARbucket_nextMonth = if_else(is.na(PARbucket_nextMonth_refi),
                                       PARbucket_nextMonth,
                                       factor(PARbucket_nextMonth_refi, levels = PARbucketLevels,
                                              labels = PARbucketLabels, ordered = TRUE))) %>%
  select(-c(PARbucket_nextMonth_refi)) %>%
  ungroup() 


# Written off if write-off month is next month
migrationData[!is.na(migrationData$WriteOffDate) & 
                (floor_date(migrationData$WriteOffDate, "month") == (migrationData$ReportDate %m+% months(1))),
              "PARbucket_nextMonth"] <- "17 Written off"

# Flag loans that went to Repaid from the PAR bucket set by the parameter PARbucketLimitForPotentialWO as Potential WO 
migrationData[as.numeric(migrationData$PARbucket) >= which(PARbucketLabels == PARbucketLimitForPotentialWO) & 
                migrationData$PARbucket_nextMonth == "00 Repaid",
              "PARbucket_nextMonth"] <- as.factor("16 Potential WO")
migrationData[migrationData$PARbucket_nextMonth == "16 Potential WO",
              "TypeOfRefinancedOrRestructured_nextMonth"] <- factor("Potential WO")

# Change RefinancingStatus to be a factor for the contamination calculation
RefinancingStatusLabels <- c("Not refinanced or restructured", "Potential refinanced", "Refinanced", "Potential restructured", "Restructured")
RefinancingStatusLevels <- as.character(1:length(RefinancingStatusLabels))
migrationData$RefinancingStatus <- factor(migrationData$RefinancingStatus,
                                          levels = RefinancingStatusLabels, 
                                          labels = RefinancingStatusLabels, ordered = TRUE)
migrationData$RefinancingStatus_nextMonth <- factor(migrationData$RefinancingStatus_nextMonth,
                                                    levels = RefinancingStatusLabels, 
                                                    labels = RefinancingStatusLabels, ordered = TRUE)

# Make sure that the next month status & PAR buckets are all NA, since otherwise they might be Repaid
migrationData[migrationData$ReportDate == max(migrationData$ReportDate), 
              c("PARbucket_nextMonth", "RefinancingStatus_nextMonth", "TypeOfRefinancedOrRestructured_nextMonth")] <- NA

# Make IFRS buckets (all >90 as one bucket; Potential WO as Written off)
migrationData$PARbucketIFRS <- migrationData$PARbucket
levels(migrationData$PARbucketIFRS) <- PARbucketLabels_IFRS
migrationData$PARbucketIFRS_nextMonth <- migrationData$PARbucket_nextMonth
levels(migrationData$PARbucketIFRS_nextMonth) <- PARbucketLabels_IFRS

# Add PAR bucket Refinanced / restructured next month
levels(migrationData$PARbucketIFRS) <- c(levels(migrationData$PARbucketIFRS),
                                         "18 Refinanced or restructured")
levels(migrationData$PARbucketIFRS_nextMonth) <- c(levels(migrationData$PARbucketIFRS_nextMonth),
                                                   "18 Refinanced or restructured")

# Set next month's IFRS PAR bucket to "Refinanced or Restructured" if they are currently not refinanced loans and became refinanced
migrationData[migrationData$RefinancingStatus == "Not refinanced or restructured" &
                migrationData$RefinancingStatus_nextMonth != "Not refinanced or restructured" &
                !is.na(migrationData$RefinancingStatus_nextMonth),
              "PARbucketIFRS_nextMonth"] <- "18 Refinanced or restructured"


# Add Contamination status
PARbucketLabels_Contamination <- levels(migrationData$PARbucketIFRS_nextMonth)
# Group by client and add all contamination buckets
migrationData <- migrationData %>%
  select(ClientNumber, LoanNumber, ReportDate, PARbucketIFRS, PARbucketIFRS_nextMonth, RefinancingStatus, RefinancingStatus_nextMonth) %>%
  group_by(ReportDate, ClientNumber) %>%
  # choose the worst PAR status by client
  summarise(Contamination_PARbucket = 
              factor(max(as.numeric(PARbucketIFRS)), levels = as.character(1:length(PARbucketLabels_Contamination)), 
                     labels = PARbucketLabels_Contamination, ordered = TRUE), 
            Contamination_PARbucket_nextMonth = 
              factor(max(as.numeric(PARbucketIFRS_nextMonth)), levels = as.character(1:length(PARbucketLabels_Contamination)), 
                     labels = PARbucketLabels_Contamination, ordered = TRUE),
            Contamination_RefinancingStatus = 
              factor(max(as.numeric(RefinancingStatus)), levels = RefinancingStatusLevels, 
                     labels = RefinancingStatusLabels, ordered = TRUE), 
            Contamination_RefinancingStatus_nextMonth = 
              factor(max(as.numeric(RefinancingStatus_nextMonth)), levels = RefinancingStatusLevels, 
                     labels = RefinancingStatusLabels, ordered = TRUE)) %>%
  ungroup() %>%
  # Add back the Contamination buckets to the dataset
  right_join(migrationData, by = c("ReportDate" = "ReportDate", "ClientNumber" = "ClientNumber"))


# # Calculate the FCY equivalent of principal and interest
migrationData <- migrationData %>%
  # add the FCY fx rate by report date
  left_join(
    # make sure FX data is unique
    distinct(
      # Select only the FCY we want
      filter(FXData, Currency == !!FCY), ReportDate, Currency, .keep_all = TRUE),
    by = "ReportDate", suffix = c("", "_FCY")) %>%
  mutate(PrincipalFCYequivalent = PrincipalLCYequivalent / FXRate_FCY,
         AccruedIRFCYequivalent = AccruedIRCurrencyLoan * FXRate / FXRate_FCY)


# Find the 4 largest business sectors and group all others to an extra bucket, as of ReportDate
Top4BusinessSectors <- migrationData %>%
  filter(ReportDate == max(ReportDate)) %>%
  group_by(BusinessSector_grouped) %>%
  summarise(Amt = sum(PrincipalFCYequivalent)) %>%
  ungroup() %>%
  top_n(4, Amt) %>% select(BusinessSector) %>% 
  lapply(as.character) %>% unlist()

migrationData$BusinessSector <- migrationData %>% select(BusinessSector) %>% lapply(as.character) %>% unlist()
migrationData$BusinessSector_grouped <- "Other"
migrationData$BusinessSector_grouped[(migrationData$BusinessSector %in% Top4BusinessSectors)] <- 
  migrationData$BusinessSector[(migrationData$BusinessSector %in% Top4BusinessSectors)]
migrationData$BusinessSector_grouped <- as.factor(migrationData$BusinessSector_grouped)



# Add the regulary risk classification next month for loans that changed loan number
# First find the RegulatorRiskClassification of next month for loans that have a new loan number
migrationData <- migrationData %>%
  mutate(ReportDate = ReportDate %m+% months(1)) %>%
  left_join(select(migrationData, ReportDate, LoanNumber, RegulatorRiskClassification),
            by = c("LoanNumber_NewLoan" = "LoanNumber", "ReportDate" = "ReportDate"),
            suffix = c("", "_NewLoan")) %>%
  # Change the reportdate back
  mutate(ReportDate = ReportDate %m-% months(1))

# Then add next month
migrationData$RegulatorRiskClassification_nextMonth[!is.na(migrationData$RegulatorRiskClassification_NewLoan)] <-
  migrationData$RegulatorRiskClassification_NewLoan[!is.na(migrationData$RegulatorRiskClassification_NewLoan)]
# Remove excess variable
migrationData <- select(migrationData, -RegulatorRiskClassification_NewLoan)

# Add repaid and written off buckets
migrationData$RegulatorRiskClassification_nextMonth <- as.character(migrationData$RegulatorRiskClassification_nextMonth)
migrationData$RegulatorRiskClassification_nextMonth[migrationData$PARbucket_nextMonth == "00 Repaid"] <- "00 Repaid"
migrationData$RegulatorRiskClassification_nextMonth[migrationData$PARbucket_nextMonth == "17 Written off"] <- "F Written off" 



# Add remaning maturity; set it to be zero if overdue
migrationData <- migrationData %>%
  mutate(RemainingMaturityYearsReportDate = as.numeric(difftime(ContractualMaturityDate, ReportDate, unit = "days"))/365) %>%
  mutate(RemainingMaturityYearsReportDate = if_else(RemainingMaturityYearsReportDate < 0, 0, RemainingMaturityYearsReportDate)) 


# Calculate next month's principal in LCY equivalent based on this month's FX rate, to be able to see repaid amounts
migrationData <- migrationData %>%
  mutate(NextMonth = ReportDate %m+% months(1)) %>%
  left_join(select(migrationData, LoanNumber, ReportDate, FXRate), 
            by = c("LoanNumber" = "LoanNumber", "NextMonth" = "ReportDate"),
            suffix = c("", "_nextMonth")) %>%
  mutate(PrincipalLCYequivalent_nextMonth_thisMonthFXrate = PrincipalCurrencyLoan_nextMonth * FXRate) %>%
  select(-c(FXRate_nextMonth))

# Make sure loans that disappeared and got replaced by another loan get another restructuring
migrationData[!is.na(migrationData$LoanNumber_NewLoan), "NumberCalculatedRestructurings_nextMonth"] <-
  migrationData[!is.na(migrationData$LoanNumber_NewLoan), "NumberCalculatedRestructurings"]+1
# Add a flag "Re-restructured" if a loan was restructured and became restructured again
migrationData <- migrationData %>%
  mutate(NumberCalculatedRestructurings_nextMonth = replace_na(NumberCalculatedRestructurings_nextMonth, 0),
         NumberCalculatedRestructurings = replace_na(NumberCalculatedRestructurings, 0),
         Re_restructured_nextMonth = if_else(NumberCalculatedRestructurings > 0 & NumberCalculatedRestructurings_nextMonth > NumberCalculatedRestructurings,
                                             "Re-restructured", "Not re-restructured"))

# Set the Number of restructurings to the max of the calculated and reported number of restructurings
migrationData$NumberRestructurings[is.na(migrationData$NumberRestructurings)] <- 0
migrationData$NumberRestructurings_nextMonth[is.na(migrationData$NumberRestructurings_nextMonth)] <- 0
migrationData$NumberRestructurings <- pmax(migrationData$NumberRestructurings, migrationData$NumberCalculatedRestructurings, na.rm = T)
migrationData$NumberRestructurings_nextMonth <- pmax(migrationData$NumberRestructurings_nextMonth, migrationData$NumberCalculatedRestructurings_nextMonth, na.rm = T)


migrationData %>%
  filter(ReportDate == max(ReportDate)) %>%
  group_by(BusinessSector_grouped) %>%
  summarise(Amt = sum(PrincipalFCYequivalent)) %>%
  ungroup() %>%
  arrange(desc(Amt))

####################################################################################################################################
# 6. Check the result (to be extended)
####################################################################################################################################

# Number of loans in each month
migrationData %>%
  select(ReportDate) %>%
  table()

# Outstanding principal by report date in LCY equivalent
migrationData %>%
  mutate(ReportDate = ReportDate %m+% months(1) %m-% days(1)) %>%
  group_by(ReportDate) %>%
  summarise(OutstandingPrincipal = sum(PrincipalLCYequivalent))


# Print total repayments, for comparison. We link loans that were (potentially) refinanced/restructured
migrationData %>%
  select(ReportDate, LoanNumber, LoanNumber_NewLoan, PrincipalLCYequivalent, PrincipalLCYequivalent_nextMonth_thisMonthFXrate) %>%
  mutate(ReportDate = ReportDate %m+% months(1)) %>%
  left_join(select(migrationData, ReportDate, LoanNumber, PrincipalLCYequivalent),
            by = c("LoanNumber_NewLoan" = "LoanNumber", "ReportDate" = "ReportDate"),
            suffix = c("", "_NewLoan")) %>%
  mutate(ReportDate = ReportDate %m-% months(1)) %>%
  mutate(PrincipalLCYequivalent_nextMonth = 
           replace_na(PrincipalLCYequivalent_nextMonth_thisMonthFXrate, 0)+
           replace_na(PrincipalLCYequivalent_NewLoan, 0),
         PrincipalLCYequivalent = replace_na(PrincipalLCYequivalent, 0),
         Repaid = PrincipalLCYequivalent - PrincipalLCYequivalent_nextMonth) %>%
  group_by(ReportDate) %>%
  summarise(Repaid = sum(Repaid, na.rm = T)) %>%
  ungroup() %>%
  # Use the commented to show amounts in USD
  # left_join(filter(FXData, Currency == "USD"),
  #           by = "ReportDate") %>%
  # Since we need next month principal, can't calculate this for the last month
  filter(ReportDate < max(ReportDate)) %>% ungroup() %>%
  # mutate(ReportDate = ReportDate %m+% months(2) %m-% days(1),
  #        Repaid = Repaid / FXRate) %>%
  arrange(ReportDate) 


# Check how many loans had zero principal but other balances outstanding - this shouldn't be, since interest repayments should be booked before principal
# Doesn't have to be a code error, but suspicious practices in the bank
migrationData %>%
  filter(PrincipalCurrencyLoan <= 0 & ((PrincipalCurrencyLoan + AccruedIRCurrencyLoan + AccruedPenaltyCurrencyLoan) > 0)) %>%
  select(ReportDate) %>%
  table() 


which(names(migrationData)=="ReportedRestructuring")


####################################################################################################################################
# 7. Save the data as rds (for Power BI and R) and csv (for Excel)
####################################################################################################################################

# Save data for Power BI or R; change all factors to characters for Power BI
migrationData <- migrationData %>% mutate_if(is.factor, as.character)
write_rds(migrationData, paste0(SaveLocation, "\\", "migrationData.rds"))


# For csv/Excel: save only the data we're more likely to use and remove NAs from number fields
migrationData$MonthsAccruedInterestOutstanding[is.infinite(migrationData$MonthsAccruedInterestOutstanding)] <- 0
migrationData$MonthsTooHighPrincipalOutstanding[is.infinite(migrationData$MonthsTooHighPrincipalOutstanding)] <- 0
migrationData %>%
  select(-c(Branch, PledgedForFunding, BusinessSubSector, 
            Region, PurposeLoan, InitialLO, CurrentLO, GroupNumber, SubGroupNumber, 
            TypeIR, LoanNumberPreviousLoan, RegulatorRestructuringClassification, 
            InternalRestructuringClassification, InternalRiskClassification, 
            RegulatorRiskClassification, RelatedPartiesWithBank, VariableIRSpread, 
            YearlyEffectiveIR, AccruedPenaltyCurrencyLoan, UnmortizedFeesCurrencyLoan, 
            NumberCalculatedRestructurings, NumberCalculatedRestructurings_nextMonth, 
            EndMoratoriumDate, EndGracePeriodDate, WriteOffDate, 
            RegulatorLLPPrincipalCurrencyLoan, RegulatorLLPAccruedInterestCurrencyLoan, 
            RegulatorLLPPenaltyInterestCurrencyLoan, IFRSLLPPrincipalCurrencyLoan, 
            IFRSLLPAccruedInterestCurrencyLoan, IFRSLLPPenaltyInterestCurrencyLoan,
            MaximumArrearsDays, YearlyNominalIR_nextMonth, ContractualMaturityDate_nextMonth)) %>%
  mutate(
    # Set report date to the end of month
    ReportDate = ReportDate %m+% months(1) %m-% days(1),
    # Replace all NAs by zeros where we use the amounts
    DisbursedAmountCurrencyLoan = replace_na(DisbursedAmountCurrencyLoan, 0),
    ArrearsDays = replace_na(ArrearsDays, 0),
    PrincipalCurrencyLoan = replace_na(PrincipalCurrencyLoan, 0),
    YearlyNominalIR = replace_na(YearlyNominalIR, 0),
    AccruedIRCurrencyLoan = replace_na(AccruedIRCurrencyLoan, 0),
    OverduePrincipalCurrencyLoan = replace_na(OverduePrincipalCurrencyLoan, 0),
    OverdueInterestCurrencyLoan = replace_na(OverdueInterestCurrencyLoan, 0),
    FXRate = replace_na(FXRate, 0),
    TotalExposure = replace_na(TotalExposure, 0),
    NetPrincipal = replace_na(NetPrincipal, 0),
    AccruedIRFCYequivalent = replace_na(AccruedIRFCYequivalent, 0),
    AccruedIRLCYequivalent = replace_na(AccruedIRFCYequivalent, 0),
    PrincipalFCYequivalent = replace_na(PrincipalFCYequivalent, 0),
    PrincipalLCYequivalent = replace_na(PrincipalLCYequivalent, 0),
    TotalExposureLCYequivalent = replace_na(TotalExposureLCYequivalent, 0),
    NetPrincipalLCYequivalent = replace_na(NetPrincipalLCYequivalent, 0),
    PrincipalCurrencyLoan_nextMonth = replace_na(PrincipalCurrencyLoan_nextMonth, 0),
    CashCollateral_nextMonth = replace_na(CashCollateral_nextMonth, 0),
    TotalExposure_nextMonth = replace_na(TotalExposure_nextMonth, 0),
    PrincipalPaidOfExpected = replace_na(PrincipalPaidOfExpected, 0),
    MonthsAccruedInterestOutstanding = replace_na(MonthsAccruedInterestOutstanding, 0),
    MonthsTooHighPrincipalOutstanding = replace_na(MonthsTooHighPrincipalOutstanding, 0),
    PrincipalLCYequivalent_nextMonth_thisMonthFXrate = replace_na(PrincipalLCYequivalent_nextMonth_thisMonthFXrate, 0),
    RemainingMaturityYearsReportDate = replace_na(RemainingMaturityYearsReportDate, 0)
  ) %>%
  write.csv(paste0(SaveLocation, "\\", "migrationData.csv"))


# In case you want to read data:
migrationData <- read_rds(paste0(SaveLocation, "\\", "migrationData.rds"))

ReportDate <- migrationData %>% 
  select(ReportDate) %>% 
  unique() %>% 
  write.csv(paste0(SaveLocation, "\\", "ReportDate.csv"))

SourceCurrency <- migrationData %>% 
  select (CurrencyLoan) %>% 
  unique() %>% 
  write.csv(paste0(SaveLocation, "\\", "SourceCurrency.csv"))




####################################################################################################################################
# 8. Calculate data for vintage curves, save output to Vintage.csv and Vintage.rds
# THIS IS NOT THE LATEST VERSION FROM VANESSA!!!!!!!!
####################################################################################################################################

# Create dataset VintageData with the columns we need
VintageData <- migrationData %>%
  select(LoanNumber, ReportDate, DisbursementDate, 
         DisbursedAmountCurrencyLoan, PrincipalCurrencyLoan,
         PrincipalLCYequivalent, 
         ArrearsDays, PARbucket, ProductType,
         ClientType, RefinancingStatus, CurrencyLoan, 
         BusinessSector, BusinessSubSector, Branch)

# Find disbursement month
VintageData$DisbMonth <- as.character(
  floor_date(migrationData$DisbursementDate, "month"))

# Calculate Months on book
VintageData <- VintageData %>%
  mutate(MonthsOnBook = interval(DisbursementDate, (ReportDate %m+% months(1) %m-% days(1))) %/% months(1))

# Add NPL amount (PAR90)
VintageData$NPLamountCurrLoan <- 0
VintageData[(as.numeric(VintageData$PARbucket) >= which(PARbucketLabels == "06 PAR 91-120")), "NPLamountCurrLoan"] <- 
  VintageData[(as.numeric(VintageData$PARbucket) >= which(PARbucketLabels == "06 PAR 91-120")), "PrincipalCurrencyLoan"]


# Add PAR30 amount
VintageData$PAR30amountCurrLoan <- 0
VintageData[(as.numeric(VintageData$PARbucket) >= which(PARbucketLabels == "04 PAR 31-60")), "PAR30amountCurrLoan"] <- 
  VintageData[(as.numeric(VintageData$PARbucket) >= which(PARbucketLabels == "04 PAR 31-60")), "PrincipalCurrencyLoan"]

# Add Restructured/Refinanced amount
VintageData$RefinancedAmountCurrLoan <- 0
VintageData[(VintageData$RefinancingStatus != "Not refinanced or restructured"), "RefinancedAmountCurrLoan"] <- 
  VintageData[(VintageData$RefinancingStatus != "Not refinanced or restructured"), "PrincipalCurrencyLoan"]


# Make the groupings we want to be able to filter on
VintageData <- VintageData %>%
  # Remove really old data
  filter(DisbMonth > ymd("2014-12-31")) %>%
  group_by(DisbMonth, MonthsOnBook, 
           ClientType, RefinancingStatus, 
           ProductType, Branch,
           CurrencyLoan, BusinessSector, BusinessSubSector) %>%
  summarise(AvgPAR = mean(ArrearsDays),
            NPLamountCurrencyLoan = sum(NPLamountCurrLoan),
            PAR30amountCurrencyLoan = sum(PAR30amountCurrLoan),
            RefinancedAmountCurrencyLoan = sum(RefinancedAmountCurrLoan),
            OutstandingCurrencyLoan = sum(PrincipalCurrencyLoan),
            DisbursedAmountCurrencyLoan = sum(DisbursedAmountCurrencyLoan))

# Inspect
summary(as.data.frame(VintageData))

# Write for Power BI
write_rds(as.data.frame(VintageData), paste0(SaveLocation, "\\", "VintageData.rds"))
# Write for excel
write_csv(as.data.frame(VintageData), paste0(SaveLocation, "\\", "VintageData.csv"))


# If you want, plot the curves
p <- VintageData %>%
  # Set the minimum of what disbursement date you want to see curves for
  filter(DisbMonth > ymd("2017-12-31")) %>%
  group_by(MonthsOnBook, DisbMonth) %>%
  summarise(NPLrate = sum(NPLamount) / sum(Outstanding)) %>%
  ggplot(aes(x = MonthsOnBook, y = NPLrate, colour = DisbMonth))

p + geom_line(size=2, alpha=1/2) +
  geom_point(size=3, alpha=1) +
  # geom_smooth(aes(group=1), method = 'loess', size=2, colour='red', se=FALSE) +
  labs(title = "Vintage analysis")





####################################################################################################################################
# 9. Calculate migration matrices and PDs (not necessary if you do this in Excel instead) - NOT COMPLETE!!!
####################################################################################################################################

# Order PAR buckets to be in the right order for the migration matrix to look right
migrationData$PARbucket = factor(migrationData$PARbucket, levels(migrationData$PARbucket)[order(levels(migrationData$PARbucket))])
migrationData$PARbucket_nextMonth = factor(migrationData$PARbucket_nextMonth, 
                                           levels(migrationData$PARbucket_nextMonth)[order(levels(migrationData$PARbucket_nextMonth))])
migrationData$PARbucketIFRS = factor(migrationData$PARbucketIFRS, 
                                     levels(migrationData$PARbucketIFRS)[order(levels(migrationData$PARbucketIFRS))])
migrationData$PARbucketIFRS_nextMonth = factor(migrationData$PARbucketIFRS_nextMonth, 
                                               levels(migrationData$PARbucketIFRS_nextMonth)[order(levels(migrationData$PARbucketIFRS_nextMonth))])


# make 1 month migration matrix just to see that it looks reasonable
migrationData %>%
  select(PARbucketIFRS, PARbucketIFRS_nextMonth) %>%
  table() %>%
  prop.table(1) %>%
  round(2)



# -------------------- Now calculate PDs for different categories

# Select grouping - THESE NEED TO BE GROUPED MANUALLY DEPENDING ON WHAT YOU WANT
groupings <- c("RefinancingStatus_grouped", "ClientType_group")

migrationData <- migrationData %>%
  mutate(RefinancingStatus_grouped = if_else(RefinancingStatus == "Not refinanced or restructured",
                                             "Not refinanced or restructured",
                                             "Refinanced or restructured"),
         ClientType_group = if_else(ClientType %in% c("Biashara", "Corporate"),
                                    "SME",
                                    "Other"))

# Calculate the MMs and PDs
matrix1month <- data.frame()
matrix12months <- data.frame()
MM1month <-  data.frame(MM = numeric(
  length(levels(migrationData$PARbucketIFRS))^2))
PDs <- data.frame(PD = numeric(5))
ProbOfRefinancing <- data.frame(PD = numeric(5))
headers <- c("Empty")
counter <- 0

# i <- levels(as.factor(migrationData$RefinancingStatus_grouped))[1]
# j <- levels(as.factor(migrationData$ClientType_group))[1]
# Make a migration matrix for every group type
for (i in levels(as.factor(migrationData$RefinancingStatus_grouped))) {
  for (j in levels(as.factor(migrationData$ClientType_group))) {
    
    counter <- counter + 1
    matrix1month <- migrationData %>%
      filter(RefinancingStatus_grouped == i & ClientType_group == j) %>%
      select(PARbucketIFRS, PARbucketIFRS_nextMonth) %>%
      table() %>%
      prop.table(1)
    
    headers[counter+1] <- paste(i, "/", j)
    print(headers[counter+1])
    
    # make sure states are absorbing
    # Repaid
    matrix1month[1,] <- c(1, rep(0, (dim(matrix1month)[2]-1)))
    # Written off
    matrix1month[(dim(matrix1month)[1]-1),] <- c(rep(0, (dim(matrix1month)[2]-2)), 1, 0)
    # Restructured/refinanced
    matrix1month[(dim(matrix1month)[1]),] <- c(rep(0, (dim(matrix1month)[2]-1)), 1)
    
    # Calculate 12 months matrix
    matrix12months <- as.data.frame(matrix1month %^% 12)
    
    # Calculate and PDs
    PDs <- bind_cols(PDs, data.frame(rowSums(matrix12months[2:6, 7:(dim(matrix1month)[1]-1)])))
    ProbOfRefinancing <- bind_cols(ProbOfRefinancing, data.frame(matrix12months[2:6, dim(matrix1month)[1]]))
    
    # Save to a table of migration matrix values
    MM1month <- bind_cols(MM1month, Freq = data.frame(matrix1month)[,3])
    
  }
}

# Add headers
names(PDs) <- headers
names(ProbOfRefinancing) <- headers
MM1month <- bind_cols(MM1month, data.frame(matrix1month)[,c(1,2)])
names(MM1month) <- c(headers,"This month", "Next month")


# Print
print(round(PDs[, -1],2))
print(round(ProbOfRefinancing[, -1],2))

# Add row names to the PDs
TotalPDs <- bind_rows(PDs[, -1], 
                      ProbOfRefinancing[, -1])
rownames(TotalPDs) <- c("Probability of default 02 No arrears", 
                        "Probability of default 01 Moratorium or Grace Period", 
                        "Probability of default 03 PAR 1-30",	
                        "Probability of default 04 PAR 31-60",
                        "Probability of default 05 PAR 61-90",	
                        "Probability of refi/restr 02 No arrears", 
                        "Probability of refi/restr 01 Moratorium or Grace Period", 
                        "Probability of refi/restr 03 PAR 1-30",	
                        "Probability of refi/restr 04 PAR 31-60",	
                        "Probability of refi/restr 05 PAR 61-90")


# Create an Excel workbook
ExcelWB <- createWorkbook()

# Write PDs to sheet PD
addWorksheet(ExcelWB, "PD")
writeData(ExcelWB, "PD", TotalPDs, rowNames = TRUE)

# Write the MM data to sheet MMData
addWorksheet(ExcelWB, "MMdata")
writeData(ExcelWB, "MMdata", MM1month[, -1])

# Save workbook to the save location
setwd(SaveLocation)
saveWorkbook(ExcelWB, file = "Migration matrix and PDs grouped.xlsx", overwrite = TRUE)







### -------------------- EXTRA
### -------------------- If you want to calculate confidence intervals for the migration matrices, use code below

if (!require(markovchain)) install.packages('markovchain')
library(markovchain)

# fit the Markov Chain - can take a while. If you only want the MM and not the confidence interval, use commented code below
MM <- migrationData %>%
  select(PARbucketIFRS, PARbucketIFRS_nextMonth) %>%
  markovchainFit()

# Print everything
MM

# Print MM
round(MM$estimate, 2)








####################################################################################################################################
# ---------------------------- DONE !!!!
# Below is some code for looking up individual loans and clients when debugging
####################################################################################################################################

migrationData %>%
  filter(LoanNumber == "LD1735592017") %>%
  select(ReportDate, PARbucket, PARbucket_nextMonth, RefinancingStatus, RefinancingStatus_nextMonth)%>%
  arrange(ReportDate)

LPData %>%
  filter(LoanNumber == "LD1735592017") %>%
  select(ClientNumber, ReportDate, ArrearsDays, RefinancingStatus, PARbucket, PrincipalCurrencyLoan, DisbursementDate, ContractualMaturityDate) %>%
  arrange(ReportDate)


LPData %>%
  filter(LoanNumber == "LD1705445406") %>%
  select(ClientNumber, ReportDate, ArrearsDays, YearlyNominalIR, ContractualMaturityDate, RefinancingStatus) %>%
  arrange(ReportDate)


LPData %>%
  filter(ClientNumber == "10100714456") %>%
  select(LoanNumber, ReportDate, ArrearsDays, PrincipalCurrencyLoan, RefinancingStatus, DisbursedAmountCurrencyLoan) %>%
  arrange(ReportDate)

migrationData %>%
  filter(LoanNumber == "11700028568") %>%
  select(ReportDate, LoanNumber_NewLoan, LoanNumber_NewLoan_Restructured, LoanNumber_NewLoan_Refinanced)


# !! Not done yet: using the field LoanNumberPreviousLoan
