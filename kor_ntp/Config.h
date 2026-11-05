#ifndef CONFIG_STANDALONE_H
#define CONFIG_STANDALONE_H

#include <string>

const std::string RawDataPath       = "./";
const std::string ProcessedDataPath = "./";
const std::string FinalResultPath   = "./";
const std::string ImagePath         = "./images/"; 

// Ch0 = EM2740A (monitor PMT), Ch1 = EL1635B (scan PMT),
// Ch2 = EL9590B (scan PMT), Ch3 = physical laser-monitor trigger.
// Verified from raw waveforms: ch3 fires in 100% of events at sample ~420
// with ~845 mV amplitude; ch0/1/2 show sparse single-photon hits in the
// PMT signal window (sample ~620).
const int TriggerCh = 3;

const std::string Laser = "";
const std::string NOTE  = "";

#endif // CONFIG_STANDALONE_H
