//============================================================================
//  asc - Enhanced Apple Sound Chip (+ DFAC) (Quadra 900/950)
//
//  Real parts: the Enhanced ASC does 4-channel 8-bit playback at ~22.257 kHz
//  (the DFAC clock). The DFAC (Digitally Filtered Audio Chip) adds the input
//  path (mic/line/CD ADC, anti-alias filter); "Sporty" is the output amp.
//  The ASC supports FIFO mode (two 1KB buffers streamed by the CPU) and a
//  wavetable/"4-voice" mode.
//
//  STATUS: stub. Outputs silence. Register map, FIFO/wavetable engines and the
//  22.257 kHz resampling to the MiSTer 16-bit stream are TODO.
//============================================================================

module asc
(
	input             clk,
	input             reset,

	// CPU register/FIFO access (wired via iobus later)
	input             sel,
	input      [11:0] addr,
	input      [7:0]  din,
	output reg [7:0]  dout,
	input             rw,
	output reg        ack,

	// 16-bit signed stereo to the framework
	output reg [15:0] audio_l,
	output reg [15:0] audio_r
);

	always @(posedge clk) begin
		audio_l <= 16'sd0;
		audio_r <= 16'sd0;
		dout    <= 8'h00;
		ack     <= sel & ~ack;
	end

	// TODO:
	//  [ ] ASC register file + IRQ.
	//  [ ] FIFO mode (2x 1KB) with half-full interrupts.
	//  [ ] 4-voice wavetable mode.
	//  [ ] 8-bit @ 22.257kHz -> signed 16-bit resample.

endmodule
