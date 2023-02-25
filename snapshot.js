// This example shows how to obtain the final results of snapshot.org off-chain vote outcome
const proposalId = args[0]

// Use snapshot's graphql API to get the final vote outcome
const snapshotRequest = () => Functions.makeHttpRequest({
  url: `https://testnet.snapshot.org/graphql`, //`https://hub.snapshot.org/graphql`,
  method: "POST",
  data: {
    query: `{
      proposal(id: "${proposalId}") {
        choices
        plugins
        quorum
        scores
        scores_state
        scores_total
      }
    }`,
  },
})

const { data, error } = await snapshotRequest()

if (error) {
  throw Error("Snapshot request failed")
}

const { proposal } = data.data
const { choices, plugins, quorum, scores, scores_state, scores_total } = proposal

if (scores_state !== "final") {
  throw Error("Snapshot vote is not final")
}

if (scores_total < quorum) {
  throw Error("Snapshot vote quorum not reached")
}

const executableIf = plugins?.safeSnap?.executableIf
const winningChoice = choices[scores.indexOf(Math.max(...scores))]

// const logTx = plugins?.safeSnap?.safes?.map((safe) => {
//   return safe?.txs?.map((tx) => {
//     return tx?.transactions?.map((tx) => {
//       return [tx.operation, tx.to, tx.value, tx.data.length, tx.data]
//     }).flat()
//   }).flat()
// }).flat().toString()
// console.log(logTx)

// const txData = plugins?.safeSnap?.safes?.map((safe) => {
//   return safe?.txs?.map((tx) => {
//     return tx?.transactions?.map((tx) => {
//       return [tx.operation, tx.to, tx.value, tx.data.length, tx.data]
//     }).flat()
//   }).flat()
// }).flat().toString()

const shouldExecute = executableIf === winningChoice

if (!shouldExecute) {
  return Error("Snpashot vote outcome should not execute")
}

const hash = plugins?.safeSnap?.safes[0]?.txs[0].hash
const txString = plugins?.safeSnap?.txString

const to = plugins?.safeSnap?.safes[0]?.txs[0].transactions[0].to
const value = plugins?.safeSnap?.safes[0]?.txs[0].transactions[0].value
const txData = plugins?.safeSnap?.safes[0]?.txs[0].transactions[0].data
const operation = plugins?.safeSnap?.safes[0]?.txs[0].transactions[0].operation

// const txString = `${to},${value},${txData},${operation}`
console.log({ txString })

// console.log(winningChoice, txData, shouldExecute, hash)
// console.log(Functions.encodeString(winningChoice, txData, shouldExecute))

// return Functions.encodeString(winningChoice, txData, shouldExecute)

// hex string without prefix
const hexStringWithoutPrefix = txString.slice(2);
console.log({ hexStringWithoutPrefix })
// convert the hex string to a buffer representing on-chain bytes
const convertedHexStringToBytesBuffer = Buffer.from(hexStringWithoutPrefix, 'hex');
console.log({ convertedHexStringToBytesBuffer: convertedHexStringToBytesBuffer?.toString() })
// return the buffer
return convertedHexStringToBytesBuffer;

// return Functions.encodeString(txString)
