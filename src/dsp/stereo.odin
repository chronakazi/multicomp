package dsp

// Mid-side encoding.
//
// Compressing M/S instead of L/R lets the centre and the sides be treated separately:
// the classic use is holding a lead vocal steady without the reverb and width pumping
// along with it.
//
// This pairing is lossless - decode(encode(l, r)) == (l, r) - so mid-side with no
// compression applied is transparent rather than merely close.

encode_mid_side :: proc "contextless" (left, right: f64) -> (mid, side: f64) {
	return (left + right) * 0.5, (left - right) * 0.5
}

decode_mid_side :: proc "contextless" (mid, side: f64) -> (left, right: f64) {
	return mid + side, mid - side
}
