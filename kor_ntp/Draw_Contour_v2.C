/* Draw_Contour_v2.C (Standalone Version)

Usage:
root -l
.x Draw_Contour_v2.C("Run123_data.root")

Functionality:
Accumulates all waveforms into a 2D histogram (Time vs ADC)
to visualize signal stability and pedestal baselines.
Saves output PNG to ./images/Contour/
*/

#include "Config.h"
#include "DrawFormat.cpp"
#include "Analysis.cpp"

#include "TChain.h"
#include "TCanvas.h"
#include "TH2.h"
#include "TSystem.h"
#include "TStyle.h"
#include "TString.h"
#include <iostream>
#include <vector>
#include <string>

void Draw_Contour_v2(const char* filename) {
  // 1. Style Settings
  gStyle->SetFrameLineWidth(4);
  gStyle->SetPalette(53); // kDarkBodyRadiator palette
  gStyle->SetNumberContours(100);
  gStyle->SetTitleFont(22,"");

  TString openPath = filename;

  // 2. Check File
  if (gSystem->AccessPathName(openPath)) {
    std::cerr << "[ERROR] Could not find data file: " << openPath << std::endl;
    return;
  }
  std::cout << "[INFO] Opening file: " << openPath << std::endl;

  // 3. Load Data
  TChain *chIn = new TChain("T");
  chIn->Add(openPath);

  if (chIn->GetEntries() == 0) {
    std::cerr << "[ERROR] No entries found." << std::endl;
    return;
  }

  chIn->LoadTree(0);
  long long NEntry = chIn->GetEntries();
  std::cout << "[INFO] Total Entries: " << NEntry << std::endl;

  unsigned int RecordLength;
  chIn->SetBranchAddress("RecordLength", &RecordLength);
  chIn->GetEntry(0);

  const int nChannels = 8;
  const int nSamples = RecordLength;
  unsigned int ADC[nChannels][nSamples];
  chIn->SetBranchAddress("ADC", ADC);

  // Detect Active Channels
  std::vector<int> channels;
  for (int i = 0; i < nChannels; ++i) {
    if (chIn->GetBranch(Form("OffsetValue%d", i))) {
      channels.push_back(i);
    }
  }
  int channelCount = channels.size();
  if (channelCount == 0) return;

  // 4. Initialize 2D Histograms
  std::vector<TH2D*> h_contours;
  for (int ch : channels) {
    h_contours.push_back(new TH2D(
          Form("h_contour_ch%d", ch),
          Form("Channel %d Contour;Sample [2ns / Sample] @500MHz;ADC Counts @2 V, 2^{14}bit", ch),
          nSamples, 0, nSamples, 
          16384, 0, 16384 )); // Full 14-bit ADC range
  }

  // 5. Fill Histograms (Accumulate Data)
  std::cout << "Processing events..." << std::endl;
  for (long long entry = 0; entry < NEntry; ++entry) {
    chIn->GetEntry(entry);

    if ((entry % 1000) == 0) {
      double percent = (entry * 100.0) / NEntry;
      printf("\rProcessing... %.1f%%", percent);
      fflush(stdout);
    }

    for (size_t i = 0; i < channels.size(); ++i) {
      int ch = channels[i];
      for (unsigned int sample = 0; sample < nSamples; ++sample) {
        h_contours[i]->Fill(sample, ADC[ch][sample]);
      }
    }
  }
  std::cout << "\n[INFO] Filling complete." << std::endl;

  // 6. Draw and Save
  TCanvas *c1 = new TCanvas("c1", "ADC Contour Plots", 800 * channelCount, 800);
  c1->Divide(channelCount, 1);

  for (size_t i = 0; i < h_contours.size(); ++i) {
    c1->cd(i + 1);
    gPad->SetGrid();
    gPad->SetLeftMargin(0.15);
    gPad->SetRightMargin(0.15); 
    gPad->SetLogz(); 

    SetHist2DStyle(h_contours[i]); 
    if(i != TriggerCh) h_contours[i]->GetYaxis()->SetRangeUser(14900, 15100); 

    h_contours[i]->Draw("COLZ");
  }
  c1->Update();

  std::string imageDir = "./images/Contour/"; 
  gSystem->mkdir(imageDir.c_str(), kTRUE); 

  std::string baseName = gSystem->BaseName(openPath.Data());
  size_t pos = baseName.find(".root");
  if (pos != std::string::npos) baseName.replace(pos, 5, "");

  std::string finalImagePath = imageDir + baseName + "_Contour.png";
  c1->SaveAs(finalImagePath.c_str());
  std::cout << "[INFO] Image saved to: " << finalImagePath << std::endl;

/*  // Cleanup
  for(auto h : h_contours) delete h;
  delete c1;
  delete chIn;
  */
}
