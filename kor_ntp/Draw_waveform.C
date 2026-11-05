/* Draw_waveform.C (Standalone Version)

Usage:
root -l
.x Draw_waveform.C("Run123_data.root")

Functionality:
Visualizes raw waveforms event by event.
Controls:
- Enter or 'n': Next event
- 'q': Quit
- Number: Jump to specific event index
*/

#include <iostream>
#include <string>
#include <vector>
#include "TChain.h"
#include "TH1D.h"
#include "TCanvas.h"
#include "TLine.h"
#include "TSystem.h"
#include "TStyle.h"
#include "Config.h"
#include "DrawFormat.cpp"
#include "Analysis.cpp"

void textsize(TH1D* hist){/* {{{ */
  gPad->SetLeftMargin(0.15);
  gPad->SetBottomMargin(0.15);
  hist->GetXaxis()->SetLabelSize(0.05);
  hist->GetYaxis()->SetLabelSize(0.05);
  hist->GetXaxis()->SetTitleSize(0.05);
  hist->GetYaxis()->SetTitleSize(0.05);
}
/* }}} */
void Draw_waveform(const char* filename) {
  gStyle->SetTitleFont(22,"");
  gStyle->SetTitleSize(0.09);
  gStyle->SetFrameLineWidth(2);

  TString openPath = filename;

  // 1. Check File Existence
  if (gSystem->AccessPathName(openPath)) { 
    std::cerr << "[ERROR] File not found: " << openPath << std::endl;
    std::cerr << "Usage: .x Draw_waveform.C(\"filename.root\")" << std::endl;
    return;
  }
  std::cout << "[INFO] Opening file: " << openPath << std::endl;

  // 2. Load Data
  TChain *chIn = new TChain("T");
  chIn->Add(openPath);
  chIn->LoadTree(0);

  long long NEntry = chIn->GetEntries();
  std::cout << "[INFO] Total Entries: " << NEntry << std::endl;

  if (NEntry == 0) return;

  unsigned int RecordLength;
  chIn->SetBranchAddress("RecordLength", &RecordLength);
  chIn->GetEntry(0); 

  const int nChannels = 8;
  const int nSamples = RecordLength;

  // Allocate ADC array
  unsigned int ADC[nChannels][nSamples];
  chIn->SetBranchAddress("ADC", ADC);

  // Detect Active Channels
  std::vector<int> channels;
  for (int i = 0; i < nChannels; ++i) {
    TString branchName1 = Form("OffsetValue%d", i);
    if (chIn->GetBranch(branchName1)) {
      channels.push_back(i);
    }
  }
  int channelCount = channels.size();
  std::cout << "[INFO] Active Channels: " << channelCount << std::endl;

  // Read Trigger Values (Thresholds) for display
  unsigned int triggerValues[nChannels];
  for(int i=0; i<nChannels; ++i) triggerValues[i] = 0;

  for (int ch : channels) {
    TString branchName = Form("TriggerValue%d", ch);
    if (chIn->GetBranch(branchName)) {
      chIn->SetBranchAddress(branchName, &triggerValues[ch]);
    }
  }

  // 3. Prepare Canvas
  TCanvas *c1 = new TCanvas("c1", "Event Viewer", 1600, 900);
  c1->Divide(2, (channelCount + 1) / 2);

  std::vector<TH1D*> histograms(channelCount);
  std::string inputQuit;
  long long entry = 0;

  // 4. Event Loop (Interactive)
  while (entry < NEntry) {
    chIn->GetEntry(entry);

    for (size_t i = 0; i < channels.size(); ++i) {
      int ch = channels[i];

      // Create or Reset Histogram
      if (!histograms[i]) {
        histograms[i] = new TH1D(Form("Channel_%d", ch),
            Form("Channel %d; Sample [2ns / Saple] @500MHz; Voltage [mV] @2 V, 2^{14}bit", ch),
            nSamples, 0, nSamples);
      } else {
        histograms[i]->Reset();
        histograms[i]->SetTitle(Form("CH %d #%lld", ch, entry));
      }

      // Fill Data (Convert ADC to mV)
      for (unsigned int sample = 0; sample < nSamples; ++sample) {
        histograms[i]->SetBinContent(sample + 1, ADC[ch][sample] * Config::ADC_to_mV);
      }

      // Draw
      c1->cd(i + 1);
      gPad->SetLeftMargin(0.15);
      gPad->SetGrid();

      SetHistStyle(histograms[i]); // From DrawFormat.cpp
      textsize(histograms[i]);
      histograms[i]->Draw("HIST");

      // Draw Threshold Line
      double ThrValue = triggerValues[ch] * Config::ADC_to_mV;
      TLine *thrLine = new TLine(0, ThrValue, nSamples, ThrValue);
      thrLine->SetLineColor(kRed);
      thrLine->SetLineWidth(2);
      thrLine->Draw("same");
    }
    c1->Update();
    gSystem->ProcessEvents();  
    // User Input
    std::cout << "[INFO] Entry #" << entry << " / " << NEntry - 1 
      << ". (Enter: Next, q: Quit, Number: Jump): ";

    std::getline(std::cin, inputQuit);

    if (inputQuit == "q" || inputQuit == "Q") {
      break; 
    } else if (inputQuit.empty() || inputQuit == "n" || inputQuit == "N") {
      entry++; 
    } else {
      try {
        long long targetEntry = std::stoll(inputQuit);
        if (targetEntry >= 0 && targetEntry < NEntry) {
          entry = targetEntry; 
        } else {
          std::cout << "[WARNING] Invalid event number." << std::endl;
        }
      } catch (...) {
        std::cout << "[WARNING] Invalid input." << std::endl;
      }
    }
  }
}
