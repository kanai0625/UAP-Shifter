/*{{{*/
#include <vector>
#include <string>
#include <iostream>
#include <TStyle.h>
#include <TChain.h>
#include <TFile.h>
#include <TTree.h>
#include <TObjArray.h>
#include <TH1D.h>
#include <TCanvas.h>
#include <TF1.h>
#include <TLine.h>
#include <TMath.h>
#include <TSystem.h>
#include <TLatex.h> 
#include <TLegend.h>
/*}}}*/

// Modified headers to match standalone style
#include "Config.h"
#include "DrawFormat.cpp"
// #include "Analysis.cpp" // Include if necessary

/*{{{*/ // Time resolution
Double_t exGausPDF(Double_t *x, Double_t *par) {
  // par[0]=A, par[1]=mu, par[2]=sigma, par[3]=tau
  Double_t xx    = x[0];
  Double_t A     = par[0];
  Double_t mu    = par[1];
  Double_t sigma = par[2];
  Double_t tau   = par[3];
  Double_t invTau = 1.0 / tau;

  Double_t z = (sigma * invTau - (xx - mu) / sigma) / TMath::Sqrt(2.0);
  Double_t expo = (sigma*sigma*invTau*invTau/2.0) - (xx - mu)*invTau;

  return A * invTau/2.0 * TMath::Exp(expo) * TMath::Erfc(z);
}/*}}}*//*}}}*/

/*{{{*/ // Dummy fit/

TF1* PreFit(TH1D* hist, double range_min, double range_max, const std::string& name)
{
  int bin_min = hist->GetXaxis()->FindBin(range_min);
  int bin_max = hist->GetXaxis()->FindBin(range_max);

  hist->GetXaxis()->SetRange(bin_min, bin_max);
  double initial_mean = hist->GetMean();
  double initial_sigma = hist->GetStdDev();
  double initial_amp = hist->GetBinContent(hist->FindBin(initial_mean));
  hist->GetXaxis()->SetRange(); 

  TF1* pre_fit = new TF1(name.c_str(), "gaus", range_min, range_max);

  pre_fit->SetParameter(0, initial_amp);
  pre_fit->SetParameter(1, initial_mean);
  pre_fit->SetParameter(2, initial_sigma); 

  hist->Fit(pre_fit, "RQN+");

  //    hist->GetXaxis()->SetRange(-2, 6); 
  return pre_fit;
}

/*}}}*/

/*{{{*/ // Total Fit
TF1* FitGaussian(TH1D* hist, double pedestal_min, double pedestal_max, double signal_min, double signal_max,
    double& signal_mean, double& signal_error, TH1D *hist2){

  double hist_min = hist->GetXaxis()->GetXmin();
  double hist_max = hist->GetXaxis()->GetXmax();

  TF1* pre_ped_fit = PreFit(hist, pedestal_min, pedestal_max, "pre_ped_gaus");
  double pre_ped_amp = pre_ped_fit->GetParameter(0);
  double pre_ped_mean = pre_ped_fit->GetParameter(1);
  double pre_ped_sigma = pre_ped_fit->GetParameter(2);

  TF1* pedestal_fit = new TF1("pedestal_gaus", "gaus", pre_ped_mean - 2 * pre_ped_sigma, pre_ped_mean + 2 * pre_ped_sigma);
  pedestal_fit->SetParameters(pre_ped_amp, pre_ped_mean, pre_ped_sigma);
  hist->Fit(pedestal_fit, "RQN+");

  TF1* pre_sig_fit = PreFit(hist2, signal_min, signal_max, "pre_sig_gaus");
  double pre_sig_amp = pre_sig_fit->GetParameter(0);
  double pre_sig_mean = pre_sig_fit->GetParameter(1);
  double pre_sig_sigma = pre_sig_fit->GetParameter(2);

  TF1* signal_fit = new TF1("signal_gaus", "gaus", pre_sig_mean - 3 * pre_sig_sigma, pre_sig_mean + 3 * pre_sig_sigma);
  signal_fit->SetParameters(pre_sig_amp, pre_sig_mean, pre_sig_sigma);
  hist2->Fit(signal_fit, "RQN+");

  int start_bin = hist->GetXaxis()->FindBin(pedestal_fit->GetParameter(1));
  int end_bin   = hist->GetXaxis()->FindBin(signal_fit->GetParameter(1));

  double valley_y = 1e9;
  int    valley_bin = -1;
  for (int b = start_bin; b <= end_bin; ++b) {
    double current_bin = hist->GetBinContent(b);
    if (current_bin > 0 && current_bin < valley_y) {
      valley_y = current_bin;
      valley_bin = b;
    }
  }
  double valley_x = (valley_bin != -1) ? hist->GetXaxis()->GetBinCenter(valley_bin) : (pre_ped_mean + pre_sig_mean) / 2.0;
  double peak_to_valley_ratio = (valley_y > 0) ? signal_fit->GetParameter(0) / valley_y : 0.0;

  std::string funcStr =
    "[0]*TMath::Exp(-0.5*TMath::Power((x-[1])/[2], 2))"  // Pedestal
    "+[3]*TMath::Exp(-0.5*TMath::Power((x-[4])/[5], 2))";  // Signal
                                                           //      "+[6]*(TMath::Erf((x-[1])/[2]) - TMath::Erf((x-[4])/[5]))"; // Backscatter

  TF1* total_fit = new TF1("total_fit", funcStr.c_str(), hist_min, hist_max);

  total_fit->SetParameter(0, pedestal_fit->GetParameter(0)); // P_ped
  total_fit->SetParameter(1, pedestal_fit->GetParameter(1)); // μ_ped
  total_fit->SetParameter(2, pedestal_fit->GetParameter(2)); // σ_ped

  total_fit->SetParameter(3, signal_fit->GetParameter(0));   // P_sig
  total_fit->SetParameter(4, signal_fit->GetParameter(1));   // μ_sig
  total_fit->SetParameter(5, signal_fit->GetParameter(2));   // σ_sig

  //    total_fit->SetParameter(6, valley_y);                     // Backscatter 진폭

  total_fit->SetParLimits(1, pre_ped_mean - 2*pre_ped_sigma, pre_ped_mean + 2*pre_ped_sigma);
  total_fit->SetParLimits(2, pre_ped_sigma * 0.5, pre_ped_sigma * sqrt(2));
  total_fit->SetParLimits(3, pre_sig_amp * 0.1, pre_sig_amp * 2.0);
  total_fit->SetParLimits(4, total_fit->GetParameter(1), total_fit->GetParameter(4) * 2);
  total_fit->SetParLimits(5, total_fit->GetParameter(1)*sqrt(2), total_fit->GetParameter(5)*sqrt(2));
  //    total_fit->SetParLimits(6, valley_y*0.5, 2*valley_y);


  hist->Fit(total_fit, "RMQ+");
  signal_mean = total_fit->GetParameter(4);
  signal_error = total_fit->GetParError(4);

  TF1* pedestal_gaus = new TF1("pedestal_gaus", "gaus", hist_min, hist_max);
  pedestal_gaus->SetParameters(total_fit->GetParameter(0), total_fit->GetParameter(1), total_fit->GetParameter(2));
  pedestal_gaus->SetLineColor(kOrange);

  TF1* signal_gaus = new TF1("signal_gaus", "gaus", hist_min, hist_max);
  signal_gaus->SetParameters(total_fit->GetParameter(3), total_fit->GetParameter(4), total_fit->GetParameter(5));
  signal_gaus->SetLineColor(kBlue);

  pedestal_gaus->Draw("SAME");
  signal_gaus->Draw("SAME");
  //noise_gaus->Draw("SAME");
  //noise_signal->Draw("SAME");
  total_fit->Draw("SAME");

  double resolution = total_fit->GetParameter(5) / total_fit->GetParameter(4) * 100;

  std::cout << "=== Charge fitting results ===" << std::endl;
  double signalMeanValue = total_fit->GetParameter(4);
  if (signalMeanValue > 2.0) {
    std::cout << "  Signal Mean: " << "\033[01;31m" << signalMeanValue << " +/- " 
      << total_fit->GetParError(4) << "\033[0m" << std::endl;
  } else {
    std::cout << "  Signal Mean: " << "\033[01;34m" << signalMeanValue << " +/- " 
      << total_fit->GetParError(4) << "\033[0m" << std::endl;
  }
  std::cout << "  Signal Sigma: " << total_fit->GetParameter(5) << std::endl;
  std::cout << "  Resolution(%): " << resolution << std::endl;

  TLine* valley_line = new TLine(valley_x, gPad->GetUymin(), valley_x, valley_y);
  valley_line->SetLineColor(kBlack); 
  valley_line->SetLineStyle(2);        
  valley_line->SetLineWidth(2);        
  //   valley_line->Draw("same");           

  TLegend *leg = new TLegend(0.6, 0.6, 0.93, 0.88);
  leg->SetBorderSize(0);
  leg->SetFillStyle(0);
  leg->SetTextFont(132);
  leg->SetTextSize(0.04);
  leg->AddEntry(hist,"Data", "l");
  leg->AddEntry(pedestal_gaus, "Pedestal", "l");
  //  leg->AddEntry(noise_gaus, "Backscattered", "l");
  //  leg->AddEntry(valley_line, "Valley", "l");
  leg->AddEntry(signal_gaus, "SPE", "l");
  //  leg->AddEntry(noise_signal,"SPE+B.S.","l");
  //  leg->AddEntry(twope_gaus, "TwoPE", "l");
  leg->AddEntry(total_fit, "Total Fit","l");
  //  leg->AddEntry(hist2, "Signal", "f");
  leg->Draw("same");

  TLatex* spe_mean_text = new TLatex(0.59, 0.525,
      Form("#mu: %.2f #pm %.3f [pC]", signal_mean, signal_error));
  spe_mean_text->SetTextFont(132);
  spe_mean_text->SetTextSize(0.04);
  spe_mean_text->SetNDC(true);
  spe_mean_text->Draw();

  TLatex* res_text = new TLatex(0.59, 0.475,
      Form("#sigma/#mu: %.2f %%", resolution));
  res_text->SetTextFont(132);
  res_text->SetTextSize(0.04);
  res_text->SetNDC(true);
  res_text->Draw();

  TLatex* pv_text = new TLatex(0.59, 0.425,
      Form("P/V: %.2f", peak_to_valley_ratio));
  pv_text->SetTextFont(132);
  pv_text->SetTextSize(0.04);
  pv_text->SetNDC(true);
  pv_text->Draw();

  return total_fit;

}
/*}}}*/

void HistFont(TH1D *hist){
  hist->GetXaxis()->SetTitleSize(0.06);
  hist->GetXaxis()->SetLabelSize(0.06);
  hist->GetYaxis()->SetTitleSize(0.06);
  hist->GetYaxis()->SetLabelSize(0.06);
}


void read_ntp_standalone(const char* processed_filename) {
  gErrorIgnoreLevel = kWarning;
  gStyle->SetTitleFont(22,"");
  gStyle->SetTitleSize(0.06);
  gStyle->SetFrameLineWidth(3);
  gStyle->SetLineWidth(3);

  // ==========================================================
  // File Path Handling (Standalone Style)
  // ==========================================================
  TString openPath = processed_filename;

  // Check if file exists
  if (gSystem->AccessPathName(openPath)) { 
    std::cerr << "[ERROR] File not found: " << openPath << std::endl; 
    return; 
  }

  TString baseName = gSystem->BaseName(openPath); 
  baseName.ReplaceAll("prd_", ""); 
  TString savePath = "result_" + baseName;

  // Determine run mode (Dark/Laser) from filename
  bool is_dark_run = (std::string(openPath.Data()).find("_dark") != std::string::npos);

  TFile *file = TFile::Open(openPath, "READ");
  if (!file || file->IsZombie()) {
    std::cerr << "[ERROR] Could not open file: " << openPath << std::endl;
    return;
  }
  std::cout << "[INFO] Successfully opened processed file: " << openPath << std::endl;

  int n_channels = 0; 
  while (true) {
    TString tree_name = TString::Format("tree_ch%d", n_channels);
    if (file->Get(tree_name)) {
      n_channels++;
    } else {
      break;
    }
  }

  std::cout << "[INFO] Detected " << n_channels << " channels from TTrees." << std::endl;

  if (is_dark_run) {
    std::cout << "[INFO] Detected Dark Mode run from filename." << std::endl;
  } else {
    std::cout << "[INFO] Detected Laser Mode run from filename." << std::endl;
  }

  // recreate file in current directory
  TFile *outFile = TFile::Open(savePath, "RECREATE");
  if (!outFile || outFile->IsZombie()) {
    std::cerr << "[ERROR] Could not create final result file: " << savePath << std::endl;
    file->Close();
    return;
  }
  std::cout << "[INFO] Created final result file: " << savePath << std::endl;

  std::vector<TTree*> outTrees(n_channels);
  // ==========================================================

  TCanvas *c1 = new TCanvas("c1_time", "Time Analysis", 1800, 800 * (n_channels-1));
  TCanvas *c2 = new TCanvas("c2_charge", "Charge Analysis", 800 * (n_channels-1), 1000);
  c1->Divide(2, n_channels-1);
  c2->Divide(n_channels-1, 1);

  double relativeQE_b, relativeQE_err_b;
  double rms_exG_b, spe_mean_b, spe_mean_error_b;

  for (int ch = 0; ch < n_channels; ++ch) {

    //==> Modifying 
    outTrees[ch] = new TTree(Form("tree_ch%d", ch), Form("Channel %d result", ch));
    outTrees[ch]->Branch("rms_exG", &rms_exG_b, "rms_exG/D");
    outTrees[ch]->Branch("spe_mean", &spe_mean_b, "spe_mean/D");
    outTrees[ch]->Branch("spe_mean_error", &spe_mean_error_b, "spe_mean_error/D");
    outTrees[ch]->Branch("relativeQE", &relativeQE_b, "relativeQE/D");
    outTrees[ch]->Branch("relativeQE_err", &relativeQE_err_b, "relativeQE_err/D");

    outFile->cd(); 

    std::string fallName = "Time_ch" + std::to_string(ch);
    if(ch == TriggerCh) fallName = "Trigger";
    TH1D *histFall = (TH1D*)file->Get(fallName.c_str());
    if (histFall) {
      c1->cd(2 * ch + 1);
      gStyle->SetOptStat("emrou");
      gPad->SetLeftMargin(0.2);
      gPad->SetBottomMargin(0.15);

      gPad->SetGrid();
      double Ymax = histFall->GetMaximum();
      histFall->GetYaxis()->SetRangeUser(0, Ymax * 1.2);
      HistFont(histFall);

      //histFall->SetTitle(Form("Response time Ch %d", ch));
      histFall->GetXaxis()->SetTitle("Sample [2ns / Sample]");
      histFall->GetYaxis()->SetTitle("Entries");
      histFall->Draw("HIST");

      TLine *line1 = new TLine(595, 0, 595, Ymax * 1.2);
      TLine *line2 = new TLine(645, 0, 645, Ymax * 1.2);
      line1->SetLineColor(kRed);
      line2->SetLineColor(kRed);
      line1->SetLineWidth(4);
      line2->SetLineWidth(4);
      line1->SetLineStyle(3);
      line2->SetLineStyle(3);
      line1->Draw();
      line2->Draw();
    }


    std::string DiffName = "Diff_ch" + std::to_string(ch);
    TH1D *histDiff = (TH1D*)file->Get(DiffName.c_str());
    if (histDiff) {
      c1->cd(2 * ch + 2);
      if(ch == TriggerCh) continue;

      gPad->SetLeftMargin(0.2);
      gPad->SetBottomMargin(0.15);

      //gStyle->SetOptStat(0);
      //gPad->SetLogy();
      gPad->SetGrid();
      double Ymax = histDiff->GetMaximum();
      histDiff->GetYaxis()->SetRangeUser(0, Ymax * 1.2);

      histDiff->GetXaxis()->SetTitle("Sample [2ns / Sample]");
      histDiff->GetYaxis()->SetTitle("Entries");
      SetHistStyle(histDiff);
      HistFont(histDiff);

      histDiff->Draw("HIST");

      Int_t binMax = histDiff->GetMaximumBin();
      double mean   = histDiff->GetXaxis()->GetBinCenter(binMax);

      int window   = 20;
      int Start    = static_cast<int>(mean) - window;
      int End      = static_cast<int>(mean) + window;

      TF1* pre_time_fit = new TF1("gaus", "gaus", Start, End);
      pre_time_fit->SetParameter(0, Ymax);
      pre_time_fit->SetParameter(1, mean);
      histDiff->Fit(pre_time_fit, "RQ+N");

      TF1 *time_fit = new TF1("gaus","gaus",Start,End);
      time_fit->SetParameter(0, Ymax);
      time_fit->SetParameter(1, mean);
      time_fit->SetParameter(2,pre_time_fit->GetParameter(2));
      histDiff->Fit(time_fit,"RQ+N");

      Double_t amp = time_fit->GetParameter(0);
      double sigma = time_fit->GetParameter(2);
      mean = time_fit->GetParameter(1);
      Double_t time_error1 = time_fit->GetParError(1);
      double rms = time_fit->GetParameter(2);

      Double_t tailExt = 30;
      Double_t tailEnd = End + tailExt;

      TF1 *exGausFit = new TF1("exGausFit", exGausPDF, Start, tailEnd, 4);
      exGausFit->SetParNames("Amplitude","Mean","Sigma","Tau");
      exGausFit->SetParameters(amp, mean, sigma, sigma);
      exGausFit->SetParLimits(3, sigma,  sigma*2.0);
      histDiff->Fit(exGausFit, "RQ+"); 
      exGausFit->SetLineColor(kRed);
      exGausFit->Draw("same");

      Double_t A_fit     = exGausFit->GetParameter(0);
      Double_t mean_fit  = exGausFit->GetParameter(1);
      Double_t time_error= exGausFit->GetParError(1);
      Double_t sigma_fit = exGausFit->GetParameter(2);
      Double_t tau_fit   = exGausFit->GetParameter(3);
      rms_exG_b = TMath::Sqrt(sigma_fit*sigma_fit + tau_fit*tau_fit);

      Double_t chi2 = exGausFit->GetChisquare();
      Double_t ndf = exGausFit->GetNDF();

      Double_t dChi2 = 0;
      if(ndf > 0) dChi2 = chi2 / ndf;
      else dChi2 = 0;

      TLegend* legTime = new TLegend(0.45, 0.45, 0.88, 0.65);
      legTime->SetBorderSize(0);
      legTime->SetFillStyle(0);
      legTime->SetTextFont(132);
      legTime->SetTextSize(0.04);
      //			legTime->AddEntry((TObject*)0, Form("%s-%s", serials[ch].c_str(),directions[ch].c_str()), "");
      legTime->AddEntry((TObject*)0,Form("TTS: %.2f [2ns / Sample]", rms_exG_b),"");
      legTime->AddEntry((TObject*)0,Form("Chi2/ndf: %.2f", dChi2),"");

      legTime->Draw("same");

      std::cout << "\033[01;33m=================Channel "<<ch<< "=======================\033[0m"  << std::endl;
      std::cout << "=== Time fitting results ===" << std::endl;
      std::cout << "  Mean  = " << exGausFit->GetParameter(1)
        << " +/- " << exGausFit->GetParError(1) << std::endl;
      std::cout << "  Sigma = " << sigma_fit << std::endl;
      std::cout << "  Tau   = " << tau_fit   << std::endl;
      if( rms_exG_b > 1.5 ) { std::cout << "\033[01;31m  RMS   = " << rms_exG_b << " [2ns / Sample]\033[0m"  << std::endl;
      } else { std::cout << "\033[01;36m  RMS   = " << rms_exG_b << " [2ns / Sample]\033[0m"  << std::endl;
      }
      //TNamed TTS(Form("TTS_ch%d", ch), std::to_string(rms_exG).c_str());
      histDiff->Write();
      //TTS.Write();
    }

    std::string picoName = "Pico_ch" + std::to_string(ch);
    TH1D *histPico = (TH1D*)file->Get(picoName.c_str());

    // Try to get PicoAbove with generalized name search or assume standard format
    // In standalone, filenames don't necessarily have run number attached in the histogram name if generic
    // But assuming the structure inside ROOT file is same as before.
    // We need to handle the case where we don't know the run number explicitly from arguments anymore.
    // Attempt to parse run number from filename if needed, or search for the histogram.

    // Strategy: Iterate over keys or construct name if run number is embedded in filename "prd_Run123_..."
    // Parse run number from processed_filename string
    std::string s_path(processed_filename);
    std::string run_str = "0";
    size_t run_pos = s_path.find("Run");
    if (run_pos != std::string::npos) {
      size_t end_pos = s_path.find("_", run_pos);
      if (end_pos != std::string::npos) {
        run_str = s_path.substr(run_pos + 3, end_pos - (run_pos + 3));
      }
    }

    std::string picoAboveName = "PicoAbove_ch" + std::to_string(ch) + "_run" + run_str; 
    TH1D *histPicoAbove = (TH1D*)file->Get(picoAboveName.c_str());

    // Fallback: if explicit run number lookup fails, try just "PicoAbove_chX" 
    if (!histPicoAbove) histPicoAbove = (TH1D*)file->Get(Form("PicoAbove_ch%d", ch));

    if (histPico && histPicoAbove) {
      double TotalEntry = histPico->GetEntries();
      double SignalEntry = histPicoAbove->GetEntries();

      double ratio = 0.0;
      double ratio_err = 0.0;

      if (TotalEntry > 0) {
        double p = SignalEntry / TotalEntry; 
        ratio = 100.0 * p;

        double p_err = sqrt(p * (1 - p) / TotalEntry);
        ratio_err = 100.0 * p_err;
      }
      std::cout << Form("Total Entry: %.0f, Signal Entry: %.0f, Ratio: (%.2f +- %.2f)%%", 
          TotalEntry, SignalEntry, ratio, ratio_err) << std::endl;

      double signal_mean = 0, signal_error = 0;

      c2->cd(ch + 1);
      TPad* mainPad = (TPad*)gPad;

      TPad *pad1 = new TPad("pad1", "pad1", 0, 0.3, 1, 1.0);
      pad1->SetBottomMargin(0); 
      pad1->SetLeftMargin(0.15);
      pad1->SetGrid();
      pad1->Draw();
      pad1->cd(); 

      gStyle->SetOptStat(0);
      gPad->SetLogy();
      histPico->SetLineWidth(2);
      //histPico->GetYaxis()->SetRangeUser(-500, 200);
      histPico->GetXaxis()->SetLabelSize(0); 
      histPico->GetYaxis()->SetTitle("Entries");
      HistFont(histPico);
      SetHistStyle(histPico);
      histPico->Draw("Hist");
      histPicoAbove->SetFillColor(30);
      histPicoAbove->SetFillStyle(3004);
      // histPicoAbove->Draw("HIST same");
      histPico->GetYaxis()->SetTitleOffset(1.2);
      gPad->SetTickx();
      gPad->SetTicky();


      TF1* total_fit_func = FitGaussian(histPico, -2., 0.9, 1.1, 2.4, signal_mean, signal_error, histPicoAbove);
      histPico->GetXaxis()->SetRangeUser(-2,6);

      mainPad->cd();
      TPad *pad2 = new TPad("pad2", "pad2", 0, 0.05, 1, 0.3);
      pad2->SetTopMargin(0); 
      pad2->SetBottomMargin(0.3);
      pad2->SetLeftMargin(0.15);
      pad2->SetGrid();
      pad2->Draw();
      pad2->cd(); 
      gPad->SetTickx();
      gPad->SetTicky();

      TH1D *h_residual = (TH1D*)histPico->Clone("h_residual");
      h_residual->Reset();
      for (int i = 1; i <= histPico->GetNbinsX(); ++i) {
        double data = histPico->GetBinContent(i);
        if (data == 0) continue; // Skip empty bins
        double error = histPico->GetBinError(i);
        double fit_val = total_fit_func->Eval(histPico->GetBinCenter(i));
        double residual = (error > 0) ? (data - fit_val) / error : 0;
        h_residual->SetBinContent(i, residual);
        h_residual->SetBinError(i, 1); // Error on the pull is 1
      }

      SetHistStyle(h_residual);

      h_residual->SetTitle("");
      h_residual->SetMarkerStyle(20);
      h_residual->SetMarkerSize(0.8);

      // Y-axis for residual
      h_residual->GetYaxis()->SetTitle("Data-Fit/Error");
      h_residual->GetYaxis()->SetNdivisions(505);
      h_residual->GetYaxis()->SetTitleSize(0.12);
      h_residual->GetYaxis()->SetTitleOffset(0.4);
      h_residual->GetYaxis()->SetLabelSize(0.12);
      h_residual->GetYaxis()->CenterTitle();

      // X-axis for residual
      h_residual->GetXaxis()->SetTitle("Charge [pC]");
      h_residual->GetXaxis()->SetTitleSize(0.12);
      h_residual->GetXaxis()->SetLabelSize(0.12);
      h_residual->Draw("P");

      h_residual->GetXaxis()->SetRangeUser(-2,6);
      // Draw a line at y=0 for reference
      TLine *zero_line = new TLine(-2, 0, 6, 0);
      zero_line->SetLineColor(kRed);
      zero_line->SetLineStyle(2);
      zero_line->Draw("same");

      spe_mean_b = signal_mean;
      spe_mean_error_b = signal_error;
      relativeQE_b = ratio;
      relativeQE_err_b = ratio_err;

      histPico->Write();
      histPicoAbove->Write();

      outTrees[ch]->Fill();

      std::cout << "\033[01;36m-------------------------------------------------\033[0m"  << std::endl;

    }

  }
  outFile->cd();
  for (auto *tree : outTrees) if(tree) tree->Write();

  // ==========================================================
  // Image Saving (Standalone Style)
  // ==========================================================
  std::string imageDir = "./images/"; 
  gSystem->mkdir(imageDir.c_str(), kTRUE); 

  std::string pngNameBase = std::string(baseName.Data());
  size_t extPos = pngNameBase.find(".root"); 
  if (extPos != std::string::npos) pngNameBase.replace(extPos, 5, "");

  std::string pngPath1 = imageDir + pngNameBase + "_time.png";
  std::string pngPath2 = imageDir + pngNameBase + "_charge.png";

  c1->SaveAs(pngPath1.c_str());
  c2->SaveAs(pngPath2.c_str()); 

  std::cout << "[INFO] Analysis Completed. Results saved to: " << savePath << std::endl;
  // outFile->Close();
  //    file->Close();
}
