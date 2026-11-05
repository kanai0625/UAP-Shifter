/* prod_ntp_v3.C (Standalone Version)

Usage: 
root -l
.x prod_ntp_v3.C("Run123_data.root")
.x prod_ntp_v3.C("Run123_data.root", "/path/to/prd_Run123_data.root")

Output:
Generates a "prd_Run123_data.root" file. If output path is omitted, it is
created in the current working directory.
*/

#include <algorithm>
#include <vector>
#include <string>
#include <iostream>
#include <cstdint>
#include <TStyle.h>
#include <TChain.h>
#include <TFile.h>
#include <TTree.h>
#include <TH1D.h>
#include <TCanvas.h>
#include <TF1.h>
#include <TLine.h>
#include <TMath.h>
#include <TSystem.h>
#include <TParameter.h>

// Include local configuration and helper files
// Ensure these files are in the same directory
#include "Config.h"         
#include "DrawFormat.cpp"   
#include "Analysis.cpp"     

// ==========================================================
// Helper Function: Pre-Fitting (Gaussian)
// ==========================================================
TF1 *PreFit(TH1D* hist, double hist_min, double hist_max, const std::string& name) {
  int bin_min = hist->GetXaxis()->FindBin(hist_min);
  int bin_max = hist->GetXaxis()->FindBin(hist_max);

  double local_max_content = -1.0;
  int local_max_bin = -1;

  // Find the peak within the specified range
  for (int b = bin_min; b <= bin_max; ++b) {
    double content = hist->GetBinContent(b);
    if (content > local_max_content) {
      local_max_content = content;
      local_max_bin = b;
    }
  }

  double mean = hist->GetBinCenter(local_max_bin);

  TF1* pre_fit = new TF1(name.c_str(), "gaus", hist_min, hist_max);
  pre_fit->SetParameter(0, local_max_content); // Amplitude
  pre_fit->SetParameter(1, mean);              // Mean

  hist->Fit(pre_fit, "RQMN+");
  return pre_fit;
}

// ==========================================================
// Helper Function: Set Histogram Font
// ==========================================================
void HistFont(TH1D *hist){
  hist->GetXaxis()->SetTitleSize(0.06);
  hist->GetXaxis()->SetLabelSize(0.06);
  hist->GetYaxis()->SetTitleSize(0.06);
  hist->GetYaxis()->SetLabelSize(0.06);
}

// ==========================================================
// Main Production Function
// ==========================================================
void prod_ntp_standalone(const char* raw_filename, const char* out_filename = "") {

  // 1. Style Settings
  gErrorIgnoreLevel = kWarning;
  gStyle->SetOptStat("emroui"); 
  gStyle->SetTitleFont(22,"");
  gStyle->SetTitleSize(0.08);
  gStyle->SetFrameLineWidth(2);

  // 2. File Path and Name Configuration
  TString inputName = raw_filename;

  // Check if file exists
  if (gSystem->AccessPathName(inputName)) {
    std::cerr << "[ERROR] File not found: " << inputName << std::endl;
    std::cerr << "Usage: .x prod_ntp_v3.C(\"filename.root\")" << std::endl;
    return;
  }

  // Auto-detect "Dark Mode" based on filename
  bool darkmode = inputName.Contains("dark", TString::kIgnoreCase);

  // Generate Output Filename (prefix "prd_")
  TString baseName = gSystem->BaseName(inputName);
  TString outName = (out_filename && out_filename[0] != '\0')
    ? TString(out_filename)
    : TString("prd_") + baseName;
  TString outDir = gSystem->DirName(outName.Data());
  if (outDir.Length() > 0 && outDir != ".") {
    gSystem->mkdir(outDir, true);
  }

  std::cout << "==================================================" << std::endl;
  std::cout << "[INFO] Input File : " << inputName << std::endl;
  std::cout << "[INFO] Output File: " << outName << std::endl;
  std::cout << "[INFO] Run Mode   : " << (darkmode ? "DARK (Noise Check)" : "LASER (Signal)") << std::endl;
  std::cout << "==================================================" << std::endl;

  // 3. Load Data
  TChain *chIn = new TChain("T");
  chIn->Add(inputName);

  long long NEntry = chIn->GetEntries();
  if (NEntry == 0) {
    std::cerr << "[ERROR] No entries found in the file." << std::endl;
    return;
  }

  // Setup event branches.  The DAQ schema changed in August 2026: static
  // acquisition settings moved from the per-event T tree to RunInfo.  Read
  // either layout so old and new raw files remain processable.
  unsigned int RecordLength = 0;
  unsigned int PostTrigger = 0;
  unsigned int TriggerTimeTag = 0;

  TFile *fInMeta = TFile::Open(inputName, "READ");
  TTree *runInfo = fInMeta
    ? dynamic_cast<TTree*>(fInMeta->Get("RunInfo"))
    : nullptr;

  const bool settingsInEventTree =
    chIn->GetBranch("RecordLength") && chIn->GetBranch("PostTrigger");
  if (settingsInEventTree) {
    chIn->SetBranchAddress("RecordLength", &RecordLength);
    chIn->SetBranchAddress("PostTrigger", &PostTrigger);
  } else {
    if (!runInfo || !runInfo->GetBranch("RecordLength") ||
        !runInfo->GetBranch("PostTrigger") || runInfo->GetEntries() == 0) {
      std::cerr << "[ERROR] RecordLength/PostTrigger are missing from both T and RunInfo."
                << std::endl;
      if (fInMeta) { fInMeta->Close(); delete fInMeta; }
      delete chIn;
      gSystem->Exit(2);
      return;
    }
    runInfo->SetBranchAddress("RecordLength", &RecordLength);
    runInfo->SetBranchAddress("PostTrigger", &PostTrigger);
    runInfo->GetEntry(0);
  }

  if (!chIn->GetBranch("TriggerTimeTag") || !chIn->GetBranch("ADC")) {
    std::cerr << "[ERROR] Required event branches ADC/TriggerTimeTag are missing."
              << std::endl;
    if (fInMeta) { fInMeta->Close(); delete fInMeta; }
    delete chIn;
    gSystem->Exit(2);
    return;
  }
  chIn->SetBranchAddress("TriggerTimeTag", &TriggerTimeTag);

  // Read the first event after binding the old-layout setting branches.
  chIn->GetEntry(0);
  constexpr int kMaxChannels = 8;
  constexpr int kMaxSamples = 1024;
  if (RecordLength == 0 || RecordLength > kMaxSamples || PostTrigger > 100) {
    std::cerr << "[ERROR] Invalid acquisition settings: RecordLength="
              << RecordLength << ", PostTrigger=" << PostTrigger << "%"
              << std::endl;
    if (fInMeta) { fInMeta->Close(); delete fInMeta; }
    delete chIn;
    gSystem->Exit(2);
    return;
  }
  const int nSamples = RecordLength;

  // ADC has a fixed uint16_t[8][1024] layout in both supported schemas.
  std::uint16_t ADC[kMaxChannels][kMaxSamples] = {};
  chIn->SetBranchAddress("ADC", ADC);

  // Detect active channels from the tree that contains the acquisition
  // settings.  In the new schema OffsetValue* is stored in RunInfo.
  std::vector<int> channels;
  for (int i = 0; i < kMaxChannels; ++i) {
    const TString offsetBranch = Form("OffsetValue%d", i);
    if (chIn->GetBranch(offsetBranch) ||
        (runInfo && runInfo->GetBranch(offsetBranch))) {
      channels.push_back(i);
    }
  }
  if (fInMeta) {
    fInMeta->Close();
    delete fInMeta;
    fInMeta = nullptr;
    runInfo = nullptr;
  }

  int channelCount = channels.size();
  if (channelCount == 0) {
    std::cerr << "[ERROR] No active channels found from OffsetValue* metadata."
              << std::endl;
    delete chIn;
    gSystem->Exit(2);
    return;
  }
  if (std::find(channels.begin(), channels.end(), TriggerCh) == channels.end()) {
    std::cerr << "[ERROR] Configured trigger channel " << TriggerCh
              << " is not active." << std::endl;
    delete chIn;
    gSystem->Exit(2);
    return;
  }
  std::cout << "[INFO] Active Channels: " << channelCount << std::endl;
  std::cout << "[INFO] Record Length  : " << nSamples << std::endl;
  std::cout << "[INFO] Settings Source: "
            << (settingsInEventTree ? "T" : "RunInfo") << std::endl;

  // 4. Set Analysis Parameters (Window settings)
  double target_THR = 5.0; // mV
  int pedStart, pedEnd, sigStart, sigEnd;
  int noiseStart, noiseEnd; // dark search window (samples)

  int trgPoint = static_cast<int>(nSamples * (1.0 - (PostTrigger / 100.0)));

  if (darkmode) {
    pedStart = 90;  pedEnd = 140;
    sigStart = 150; sigEnd = 200;
    noiseStart = 25; noiseEnd = 325; // 50~650 ns
  } else {
    // Dynamic pedestal window: 20% of record ending 20 samples before the
    // hardware trigger point. Ported from prod_ntp_v3.C so the window
    // adapts to PostTrigger settings instead of hardcoded [200, 400].
    pedEnd   = trgPoint - 20;
    pedStart = pedEnd - static_cast<int>(nSamples * 0.2);
    if (pedStart < 0)        pedStart = 0;
    if (pedEnd   > nSamples) pedEnd   = nSamples;
    if (pedEnd <= pedStart)  pedEnd   = pedStart + 1;

    sigStart = 595; sigEnd = 645;
    if (sigEnd > nSamples) {
      std::cerr << "[ERROR] Signal window [" << sigStart << ", " << sigEnd
                << "] exceeds RecordLength=" << nSamples << std::endl;
      delete chIn;
      gSystem->Exit(2);
      return;
    }

    // Dark search window: 50~650 ns (samples 25~325), fixed before trigger.
    // Aligned with PDF spec (~600 ns), avoids edge noise near t=0.
    noiseStart = 25;
    noiseEnd   = 325;
    if (noiseEnd > trgPoint - 50) noiseEnd = trgPoint - 50; // safety: stay before trigger
    if (noiseEnd <= noiseStart)   noiseEnd = noiseStart + 1;
  }

  double Config_DarkWindow_ns = (double)(noiseEnd - noiseStart) * 2.0;
  double Config_SigWindow_ns  = (double)(sigEnd  - sigStart)  * 2.0;

  std::cout << "[INFO] Pedestal window: [" << pedStart << ", " << pedEnd
            << "] (trgPoint=" << trgPoint << ", PostTrigger=" << PostTrigger << "%)" << std::endl;
  std::cout << "[INFO] Signal   window: [" << sigStart << ", " << sigEnd
            << "] (" << Config_SigWindow_ns << " ns)" << std::endl;
  std::cout << "[INFO] Dark     window: [" << noiseStart << ", " << noiseEnd
            << "] (" << Config_DarkWindow_ns << " ns)" << std::endl;
  std::cout << "[INFO] Threshold       : " << target_THR << " mV (both signal & dark)" << std::endl;

  // 5. Initialize Output File and Trees
  TFile *fOut = new TFile(outName, "RECREATE");

  std::vector<TTree*> outTrees(channelCount);
  std::vector<TH1D*> histPed(channelCount), histMax(channelCount), 
    histFall(channelCount), histDiff(channelCount), 
    histPico(channelCount), histPicoAbove(channelCount);

  // Vectors for temporary data storage
  std::vector<std::vector<double>> max_vec(channelCount), pico_vec(channelCount);
  std::vector<long long> threshold_cross_counts(channelCount, 0LL);
  std::vector<double> threshold_cross_counts_rate(channelCount, 0.0);

  // Tree Branch Variables
  double LiveTime_b, pedestal_b, threshold_b, falltime_b, pico_b, diff_b, max_b;
  int max_time_b;

  for (int i = 0; i < channelCount; ++i) {
    int ch = channels[i];

    outTrees[i] = new TTree(Form("tree_ch%d", ch), Form("Channel %d Data", ch));
    outTrees[i]->Branch("LiveTime", &LiveTime_b, "LiveTime/D");
    outTrees[i]->Branch("falltime", &falltime_b, "falltime/D");
    outTrees[i]->Branch("diff", &diff_b, "diff/D");
    outTrees[i]->Branch("max", &max_b, "max/D");
    outTrees[i]->Branch("max_time", &max_time_b, "max_time/I");
    outTrees[i]->Branch("pico", &pico_b, "pico/D");

    // Initialize Histograms
    histPed[i]  = new TH1D(Form("Ped_ch%d", ch), Form("Pedestal CH%d", ch), 100, 14950, 15150);
    histMax[i]  = new TH1D(Form("Max_ch%d", ch), Form("Pulse Height CH%d", ch), 220, -20, 200);
    histFall[i] = new TH1D(Form("Time_ch%d", ch), Form("PMT Response Time CH%d", ch), nSamples, 0, nSamples);
    histDiff[i] = new TH1D(Form("Diff_ch%d", ch), Form("Trigger - PMT Time CH%d", ch), nSamples, 0, nSamples);
    histPico[i] = new TH1D(Form("Pico_ch%d", ch), Form("Charge CH%d", ch), 300, -5, 10);
  }

  double LiveTime = 0.0;
  unsigned int TriggerTimeTag_prev = 0;

  // 6. Event Loop
  std::cout << "===== Processing Events =====" << std::endl;
  for (int iEntry = 0; iEntry < NEntry; ++iEntry) {
    if (iEntry % 1000 == 0) {
      printf("\rProcessing... %.1f%%", (double)iEntry / NEntry * 100.0);
      fflush(stdout);
    }
    chIn->GetEntry(iEntry);

    // Calculate LiveTime
    double TriggerTimeTagDiff = (double)TriggerTimeTag - (double)TriggerTimeTag_prev;
    if (TriggerTimeTagDiff < 0.) TriggerTimeTagDiff += pow(2, 31);
    if (iEntry != 0) LiveTime += TriggerTimeTagDiff * 8.0 * 1e-9; // Assuming 8ns unit
    TriggerTimeTag_prev = TriggerTimeTag;

    // Find Trigger Time (TriggerCh defined in Config.h)
    int triggerTime = GetTimeAtThreshold(ADC[TriggerCh], 14000.0, nSamples);

    for (int i = 0; i < channelCount; ++i) {
      int ch = channels[i];

      // Calculate Pedestal and Threshold
      pedestal_b = GetPedestal(ADC[ch], pedStart, pedEnd, nSamples);
      threshold_b = pedestal_b - (target_THR / Config::ADC_to_mV);

      // Noise Count (Check for threshold crossing in the dark window [noiseStart, noiseEnd])
      int hitCountInThisEvent = GetCountBelowThreshold(ADC[ch], threshold_b, nSamples, noiseStart, noiseEnd);
      if (hitCountInThisEvent > 0) {
        threshold_cross_counts[i] += hitCountInThisEvent;
      }

      // Calculate Main Parameters
      falltime_b = GetTimeAtThreshold(ADC[ch], threshold_b, nSamples);
      diff_b = falltime_b - triggerTime;

      auto peak = GetPeakInfo(ADC[ch], pedestal_b, sigStart, sigEnd, nSamples);
      max_b = peak.first;
      max_time_b = peak.second;

      pico_b = GetCharge(ADC[ch], pedestal_b, sigStart, sigEnd, nSamples);

      // Fill Histograms
      if(pedestal_b != 0) histPed[i]->Fill(pedestal_b);
      if(max_b != 0) histMax[i]->Fill(max_b);
      if(falltime_b >= 0) histFall[i]->Fill(falltime_b);
      if(diff_b != 0) histDiff[i]->Fill(diff_b);
      histPico[i]->Fill(pico_b);

      // Store raw values for later processing
      max_vec[i].push_back(max_b);
      pico_vec[i].push_back(pico_b);

      LiveTime_b = LiveTime;
      outTrees[i]->Fill();
    }
  }
  std::cout << "\n[INFO] Event Loop Completed." << std::endl;

  // 7. Finalize and Save Results
  double noiseWindowTime = Config_DarkWindow_ns * 1e-9;
  double totalNoiseLiveTime = (double)NEntry * noiseWindowTime;

  std::cout << "===== Noise Analysis =====" << std::endl;
  for (int i = 0; i < channelCount; ++i) {
    int ch = channels[i];
    if (ch == TriggerCh) continue; 

    if (totalNoiseLiveTime > 0) {
      threshold_cross_counts_rate[i] = (double)threshold_cross_counts[i] / totalNoiseLiveTime;
    }
    std::cout << Form("CH%d Noise Rate: %.2f Hz", ch, threshold_cross_counts_rate[i]) << std::endl;
  }

  // Preserve scan provenance for new run-number-only filenames.  Downstream
  // UAP readers use this copy when serial/angle fields are absent from the
  // filename.
  TFile *fProvenance = TFile::Open(inputName, "READ");
  TTree *sourceRunInfo = fProvenance
    ? dynamic_cast<TTree*>(fProvenance->Get("RunInfo"))
    : nullptr;
  if (!sourceRunInfo || sourceRunInfo->GetEntries() == 0) {
    std::cerr << "[ERROR] Cannot copy required RunInfo provenance." << std::endl;
    if (fProvenance) { fProvenance->Close(); delete fProvenance; }
    fOut->Close();
    delete fOut;
    delete chIn;
    gSystem->Exit(2);
    return;
  }
  fOut->cd();
  TTree *outputRunInfo = sourceRunInfo->CloneTree(-1, "fast");
  if (!outputRunInfo) {
    std::cerr << "[ERROR] Failed to clone RunInfo provenance." << std::endl;
    fProvenance->Close();
    delete fProvenance;
    fOut->Close();
    delete fOut;
    delete chIn;
    gSystem->Exit(2);
    return;
  }
  outputRunInfo->SetName("RunInfo");
  outputRunInfo->Write();
  fProvenance->Close();
  delete fProvenance;

  fOut->cd();

  for (int i = 0; i < channelCount; ++i) {
    int ch = channels[i];
    if (ch == TriggerCh) continue;

    // Save Noise Info as Parameters
    TParameter<long long> noiseCount(Form("NoiseCount_ch%d", ch), threshold_cross_counts[i]);
    noiseCount.Write();
    TParameter<double> pNoiseRate(Form("NoiseCountRate_ch%d", ch), threshold_cross_counts_rate[i]);
    pNoiseRate.Write();
    // Config metadata (for downstream analysis scaling)
    (new TParameter<double>(Form("Config_Threshold_mV_ch%d", ch), target_THR))->Write();
    (new TParameter<double>(Form("Config_SigWindow_ns_ch%d",  ch), Config_SigWindow_ns))->Write();
    (new TParameter<double>(Form("Config_DarkWindow_ns_ch%d", ch), Config_DarkWindow_ns))->Write();

    // Create PicoAbove (Charge distribution above threshold)
    histPicoAbove[i] = (TH1D*)histPico[i]->Clone(Form("PicoAbove_ch%d", ch));
    histPicoAbove[i]->Reset();

    // Simple threshold check for signal charge (e.g., max > 25 ADC)
    double manual_thr_adc = 25.0; 
    for(size_t k=0; k<max_vec[i].size(); ++k){
      if(max_vec[i][k] > manual_thr_adc) {
        histPicoAbove[i]->Fill(pico_vec[i][k]);
      }
    }
    histPicoAbove[i]->Write();
  }

  // Write Trees and Histograms
  for (auto *tree : outTrees) if(tree) tree->Write();
  for (auto *hist : histPed) if(hist) hist->Write();
  for (auto *hist : histMax) if(hist) hist->Write();
  for (auto *hist : histFall) if(hist) hist->Write();
  for (auto *hist : histDiff) if(hist) hist->Write();
  for (auto *hist : histPico) if(hist) hist->Write();

  fOut->Close();
  std::cout << "[INFO] Production file saved: " << outName << std::endl;

  // Clean up
  delete chIn;
  delete fOut;
}
