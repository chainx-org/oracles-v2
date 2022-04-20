readSourcesWithSetzer()  {
	local _assetPair="$1"
	local _setzerAssetPair="$1"
	_setzerAssetPair="${_setzerAssetPair/\/}"
	_setzerAssetPair="${_setzerAssetPair,,}"
	local _prices

	_prices=$(ETH_RPC_URL="$SETZER_ETH_RPC_URL" \
		setzer sources "$_setzerAssetPair" \
		| parallel \
			-j${OMNIA_SOURCE_PARALLEL:-0} \
			--termseq KILL \
			--timeout "$OMNIA_SRC_TIMEOUT" \
			_mapSetzer "$_setzerAssetPair"
	)

	local _price
	local _source
	local _median=$(getMedian $(jq -sr 'add|.[]' <<<"$_prices"))
	verbose "median => $_median"

	jq -cs \
		--arg a "$_assetPair" \
		--argjson m "$_median" '
		{ asset: $a
		, median: $m
		, sources: .|add
		}' <<<"$_prices"
}

_mapSetzer() {
	if [[ -n $OMNIA_DEBUG ]]; then set -x; fi
	local _assetPair=$1
	local _source=$2
	local _price=$(ETH_RPC_URL="$SETZER_ETH_RPC_URL" setzer price "$_assetPair" "$_source")
	if [[ -n "$_price" && "$_price" =~ ^([1-9][0-9]*([.][0-9]+)?|[0][.][0-9]*[1-9]+[0-9]*)$ ]]; then
		jq -nc \
			--arg s $_source \
			--arg p "$(LANG=POSIX printf %0.10f "$_price")" \
			'{($s):$p}'
	else
		echo "[$(date "+%D %T")] [E] $1" >&2
	fi
}
export -f _mapSetzer

readSourcesWithGofer()   {
	local _output
	_output=$(gofer price --config "$GOFER_CONFIG" --format json "$@")

	pcx_price=$(echo "$_output" | jq -c '
		.[]
		| {
			asset: (.base+"/"+.quote),
			median: .price,
			sources: (
				[ ..
				| select(type == "object" and .type == "origin" and .error == null)
				| {(.base+"/"+.quote+"@"+.params.origin): (.price|tostring)}
				]
				| add
			)
		}
		| .median
	')

	pcx_wksx_reserves=$(seth call --async "0x2E98727Fe6BE98EDD7FB0FF699c779092B391206" "getReserves()")
	wksx_reserves="0x${pcx_wksx_reserves: 2: 64}"
	pcx_reserves="0x${pcx_wksx_reserves: 66: 64}"
	wksx_ratio=$(seth --to-dec "$(seth call --async "0xf4fFbD250415d12Bb5Aa498CCE28ECbe85fB7141" "getAmountOut(uint, uint, uint)" 1000000000000000000 "$wksx_reserves" "$pcx_reserves")")
	wksx_price=$(printf "%.8f" "$(echo "scale=8; ($wksx_ratio*$pcx_price)/(10^8)" | bc -l)")

	wksx_sbtc_reserves=$(seth call --async "0x283143be67b8444a21caca116095df261acb9f09" "getReserves()")
	wksx_reserves="0x${wksx_sbtc_reserves: 2: 64}"
	sbtc_reserves="0x${wksx_sbtc_reserves: 66: 64}"
	sbtc_ratio=$(seth --to-dec "$(seth call --async "0xf4fFbD250415d12Bb5Aa498CCE28ECbe85fB7141" "getAmountOut(uint, uint, uint)" 100000000 "$sbtc_reserves" "$wksx_reserves")")
	sbtc_price=$(printf "%.8f" "$(echo "scale=8; ($sbtc_ratio*$wksx_price)/(10^18)" | bc -l)")

	ksxusd='{"asset":"KSX/USD","median":'$wksx_price',"sources":{"KSX/USD@soswap": "'$wksx_price'"}}'
	sbtcusd='{"asset":"SBTC/USD","median":'$sbtc_price',"sources":{"SBTC/USD@soswap": "'$sbtc_price'"}}'
	echo "$ksxusd$sbtcusd" | jq -c
}