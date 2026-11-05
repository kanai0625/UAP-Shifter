#include <cstdint>

namespace Config {
	static const double ADC_to_mV = 0.1220703125;
	static const double Impedence = 50.0; // Ohm
	static const double TimePerSample = 2.0; // ns
}

double GetPedestal(const std::uint16_t* wave_data, int ped_start, int ped_end, int nSamples) {
	if (!wave_data || ped_start < 0 || ped_end > nSamples || ped_start >= ped_end) return 0.0;

	double sum = 0.0;
	for (int i = ped_start; i < ped_end; ++i) {
		sum += static_cast<double>(wave_data[i]);
	}
	return sum / (ped_end - ped_start);
}

double GetCharge(const std::uint16_t* wave_data, double pedestal, int sig_start, int sig_end, int nSamples) {
	if (!wave_data || sig_start >= sig_end || sig_end > nSamples) {
		std::cout << "Check for range! " << std::endl;
		return 0.0;
	}

	double integral = 0.0;
	for (int i = sig_start; i < sig_end; ++i) {
		integral += (pedestal - static_cast<double>(wave_data[i]));
	}

	// Charge [pC] = TimePerSample[ns] * (ADC_to_mV * integral) / Impedence[Ohm]
	double charge_pC = Config::TimePerSample * (Config::ADC_to_mV * integral) / Config::Impedence;
	return charge_pC;
}

std::pair<double, int> GetPeakInfo(const std::uint16_t* wave_data, double pedestal, int sig_start, int sig_end, int nSamples) {
	if (!wave_data || sig_start >= sig_end || sig_end > nSamples) {
		std::cout << "Check for range! " << std::endl;
		return {-1e9, -1}; 
	}

	double max_amp = -1e9;
	int max_time = -1; 

	for (int i = sig_start; i < sig_end; ++i) {
		double signal = pedestal - static_cast<double>(wave_data[i]);
		if (signal > max_amp) {
			max_amp = signal;
			max_time = i; 		
		}
	}
	return std::make_pair(max_amp, max_time); 
}

int GetTimeAtThreshold(const std::uint16_t* wave_data, double threshold, int nSamples, int searchStart = 0, int searchEnd = -1) {
    if (!wave_data) return -1;

    if (searchEnd == -1) {
        searchEnd = nSamples;
    }

    if (searchStart < 0) searchStart = 0;
    if (searchEnd > nSamples) searchEnd = nSamples;
    if (searchStart >= searchEnd) return -1; 

    for (int iSample = searchStart; iSample < searchEnd; ++iSample) {
        if (static_cast<double>(wave_data[iSample]) < threshold) {
            return iSample; 
        }
    }
    return -1; 
}

int GetCountBelowThreshold(const std::uint16_t* wave_data, double threshold, int nSamples, int searchStart = 0, int searchEnd = -1) {
    if (!wave_data) return 0;

    if (searchEnd == -1) {
        searchEnd = nSamples;
    }

    if (searchStart < 0) searchStart = 0;
    if (searchEnd > nSamples) searchEnd = nSamples;
    if (searchStart >= searchEnd) return 0;

    int hitCount = 0;
    bool isBelowThreshold = false; 

    for (int iSample = searchStart; iSample < searchEnd; ++iSample) {

        bool currentSampleIsBelow = (static_cast<double>(wave_data[iSample]) < threshold);

        if (currentSampleIsBelow && !isBelowThreshold) {
            
            hitCount++;
            isBelowThreshold = true; 
        }
        else if (!currentSampleIsBelow && isBelowThreshold) {
            isBelowThreshold = false; 
        }
    }

    return hitCount;
}
