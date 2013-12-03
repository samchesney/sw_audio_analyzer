#include <platform.h>
#include <xs1.h>
#include <xs1_su.h>
#include <math.h>
#define XSCOPE_DEBUG
#ifdef XSCOPE_DEBUG
#include <xscope.h>
#endif //XSCOPE_DEBUG
#include "i2s_master.h"
#include "app_global.h"
#include "ports.h"
#include "fft.h"

#include "debug_print.h"
#include "analyzer.h"

void audio_hw_init(unsigned);
void audio_hw_config(unsigned samFreq);

#ifdef XSCOPE_DEBUG
void xscope_user_init(void) {
      xscope_register(2,
                      XSCOPE_CONTINUOUS, "ADC-DAC",
                      XSCOPE_UINT, "adc-dac",
                      XSCOPE_CONTINUOUS, "M_S",
                      XSCOPE_UINT, "mag_spectrum");
}

void output_data_adc_dac(unsigned int data_value_1) {
  xscope_int(0, data_value_1);
}

void output_data_mag_spec(unsigned int data_value_1) {
  xscope_int(1, data_value_1);
}
#endif //XSCOPE_DEBUG

void magnitude_spectrum(unsigned sig1[], unsigned sig2[], unsigned magSpectrum[])
{
	int  im[FFT_POINTS];
	int sig[FFT_POINTS];

	// Mixing signals
	for (int i=0; i<FFT_POINTS; i++)
	{
		sig[i] = sig1[i] + sig2[i];
		im[i] = 0;
	}
	// FFT
	fftTwiddle(sig, im, FFT_POINTS);
	fftForward(sig, im, FFT_POINTS, FFT_SINE);

	// Magnitude spectrum
	for (int i=0; i<FFT_POINTS; i++){
		magSpectrum[i] = sig[i]*sig[i] + im[i]*im[i];
#if LOG_SPEC
		magSpectrum[i] = (magSpectrum[i]>0)? 10*log(magSpectrum[i]):0;
#endif
	}
}

#define PEAK_RANGE 			5
#define OTHER_ENERGY_THRESH	50000   //TODO: adjust its validity during tests
#define GLITCH_THRESHOLD	100000  //TODO: adjust its validity during tests

void audio_analyzer()
{
  unsigned sig1[FFT_POINTS], sig2[FFT_POINTS];
  unsigned mag_spec[FFT_POINTS];
  unsigned max_mag_spec_val = 0;
  unsigned max_mag_spec_idx = 0;
  unsigned index = 0;
  unsigned peak_energy;
  unsigned other_energy;
  unsigned other_energy_ctr = 0;

  while (1) {
	  peak_energy = 0;
	  other_energy = 0;
	  other_energy_ctr = 0;

	  // compute magnitude spectrum of the signals
	  for (int i=0; i<FFT_POINTS; i++){
	    sig1[i] = get_audio_data();
		sig2[i] = sig1[index];
	  }
	  magnitude_spectrum(sig1, sig2, mag_spec);
	  mag_spec[0] = 0;	// Set DC component to 0
	  max_mag_spec_val = 0;
	  max_mag_spec_idx = 0;

#ifdef XSCOPE_DEBUG
	  for (int i=0; i<FFT_POINTS; i++) {
		////output_data_mag_spec(mag_spec[i]);
	  }
#endif //XSCOPE_DEBUG

	  /* compute spectral peak */
	  for (int i=0; i<FFT_POINTS/2; i++) {
		if (max_mag_spec_val < mag_spec[i]) {
		  max_mag_spec_val = mag_spec[i];
		  max_mag_spec_idx = i;
		}
	  }
	  write_spectral_result(max_mag_spec_idx, max_mag_spec_val);

	  //perform glitch analysis
	  int tmp_idx = 0;
	  for(int i=(-PEAK_RANGE); i<= PEAK_RANGE;i++) {
		  tmp_idx = max_mag_spec_idx+i;
		  if (( tmp_idx >= 0) && (tmp_idx < (FFT_POINTS/2)))
			peak_energy += mag_spec[tmp_idx];
	  }

	  for (int i=0; i<FFT_POINTS/2; i++) {
        if((i < (max_mag_spec_idx-PEAK_RANGE)) || (i > (max_mag_spec_idx+PEAK_RANGE))) {
          if(mag_spec[i] > OTHER_ENERGY_THRESH) {
        	other_energy += mag_spec[i];
        	other_energy_ctr++;
          }
        }
	  }
	  peak_energy /= (PEAK_RANGE*2+1);
	  other_energy /= (other_energy_ctr-(PEAK_RANGE*2+1));
      if(other_energy > (GLITCH_THRESHOLD)) {
    	;
    	//glitch suspected!!!
      }

  } //end of while(1)
}

void signal_sampler()
{
  /* Audio sample buffers */
  unsigned sampsAdc[I2S_MASTER_NUM_CHANS_ADC];
  timer t;
  unsigned time;
  int data = 0;
  int time_idx = 0;

  /* Samples init */
  for (int i = 0; i < I2S_MASTER_NUM_CHANS_ADC; i++)  {
      sampsAdc[i] = 0;
  }

  t :> time;

  while (1) {
	  select {
      	  //TODO: to add xta timing constraint, not to break the signal generation period
		  case t when timerafter(time+(XS1_TIMER_HZ/SAMP_FREQ)):> time:
	      {
			write_audio_data(data);
        	//TODO: move this freq based signal generation into a look-up or auto generation
			data = 2048*sin(2*3.1415926535*(SIGNAL_FREQ/SAMP_FREQ)*time_idx);
#ifdef XSCOPE_DEBUG
  				////output_data_adc_dac(data);
#endif //XSCOPE_DEBUG
			time_idx = (time_idx+1)%(XS1_TIMER_HZ/SAMP_FREQ);
	      }
		  break;

          default:
        	if (do_spectral_analysis())
        	  analyze_spectral_peaks();
          break;
          //TODO: add i2s audio core interface
	  }
  }
}

int main(){
	par {
		on tile[0]: audio_analyzer();
		on tile[0]: signal_sampler();
#if 0
        on tile[AUDIO_IO_CORE] :
        {
            unsigned mclk_bclk_div = MCLK_FREQ/(SAMP_FREQ * 64);
            audio_hw_init(mclk_bclk_div);
            audio_hw_config(SAMP_FREQ);
            i2s_master(i2s_resources, c_data, mclk_bclk_div);
        }
#endif
	}

	return 0;
}

