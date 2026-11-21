import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { ethers } from "ethers";

// One-shot signer for the two pause proposals. Self-checking: every calldata is
// rebuilt from first principles below and compared before anything is sent.
const GOVERNOR="0xa812904860c615FeCE377F17F87670EcA0E0899c", TREASURY="0x5169ce023c76f516710395BDad053d935C054aa2";
const GUARDIAN="0xe33c9718767fe77C610Ad4F7DA29dA58Ca0a85Ee", OLD="0x60752E5762C4eC606730bad3806a1139825BC2e6";
const V2="0x17624a2DCCc71E4c35DA97d633025fE2badD3477", POL="0xBdc9687DF650B8eF5Bc7a9d9a9ABE5A18a6DbAF8", RM="0x3138855f8EdAA2D41f1a2Ae5Cc0C0052b61e9de3";
const ROUTE=0, CRITICAL=1, FOR=1;
const DESC="PAUSE-1: make the replacement EmergencyGuardian able to pause, retire the old guardian's pause roles, register the four pausable targets, and reduce the primary timelock delay from 48 hours to 12 hours. No value moves.";
const ROUTINE={"targets":["0xe33c9718767fe77C610Ad4F7DA29dA58Ca0a85Ee","0xe33c9718767fe77C610Ad4F7DA29dA58Ca0a85Ee","0xe33c9718767fe77C610Ad4F7DA29dA58Ca0a85Ee"],"calldatas":["0x3d503caf00000000000000000000000017624a2dccc71e4c35da97d633025fe2badd3477","0x3d503caf000000000000000000000000bdc9687df650b8ef5bc7a9d9a9abe5a18a6dbaf8","0x3d503caf0000000000000000000000003138855f8edaa2d41f1a2ae5cc0c0052b61e9de3"]};
const CRIT={"targets":["0x17624a2DCCc71E4c35DA97d633025fE2badD3477","0xBdc9687DF650B8eF5Bc7a9d9a9ABE5A18a6DbAF8","0x3138855f8EdAA2D41f1a2Ae5Cc0C0052b61e9de3","0x17624a2DCCc71E4c35DA97d633025fE2badD3477","0xBdc9687DF650B8eF5Bc7a9d9a9ABE5A18a6DbAF8"],"calldatas":["0x2f2ff15d55435dd261a4b9b3364963f7738a7a662ad9c84396d64be3365284bb7f0a5041000000000000000000000000e33c9718767fe77c610ad4f7da29da58ca0a85ee","0x2f2ff15d55435dd261a4b9b3364963f7738a7a662ad9c84396d64be3365284bb7f0a5041000000000000000000000000e33c9718767fe77c610ad4f7da29da58ca0a85ee","0x2f2ff15d65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a000000000000000000000000e33c9718767fe77c610ad4f7da29da58ca0a85ee","0xd547741f55435dd261a4b9b3364963f7738a7a662ad9c84396d64be3365284bb7f0a504100000000000000000000000060752e5762c4ec606730bad3806a1139825bc2e6","0xd547741f55435dd261a4b9b3364963f7738a7a662ad9c84396d64be3365284bb7f0a504100000000000000000000000060752e5762c4ec606730bad3806a1139825bc2e6"]};
const ABI=["function propose(uint8,address[],uint256[],bytes[],string) returns (uint256)","function castVote(uint256,uint8) returns (uint256)","function queue(uint256) returns (uint256)","function execute(uint256) payable returns (uint256)","function proposalCount() view returns (uint256)","function hasVoted(uint256,address) view returns (bool)","function proposals(uint256) view returns (address proposer,uint8 proposalType,bool executed,bool cancelled,bool queued,bytes32 descriptionHash,uint256 snapshotBlock,uint256 snapshotTotalSupply,uint256 voteStart,uint256 voteEnd,uint256 forVotes,uint256 againstVotes,uint256 abstainVotes,uint256 snapshotQuorumBps)"];
const ROLES=["function grantRole(bytes32,address)","function revokeRole(bytes32,address)","function registerPausable(address)"];
function check(){
 const iface=new ethers.Interface(ROLES);
 const g=ethers.keccak256(ethers.toUtf8Bytes("GUARDIAN_ROLE"));
 const p=ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE"));
 const crit=[iface.encodeFunctionData("grantRole",[g,GUARDIAN]),iface.encodeFunctionData("grantRole",[g,GUARDIAN]),iface.encodeFunctionData("grantRole",[p,GUARDIAN]),iface.encodeFunctionData("revokeRole",[g,OLD]),iface.encodeFunctionData("revokeRole",[g,OLD])];
 const rout=[iface.encodeFunctionData("registerPausable",[V2]),iface.encodeFunctionData("registerPausable",[POL]),iface.encodeFunctionData("registerPausable",[RM])];
 if(JSON.stringify(crit)!==JSON.stringify(CRIT.calldatas))throw new Error("critical calldata self-check failed");
 if(JSON.stringify(rout)!==JSON.stringify(ROUTINE.calldatas))throw new Error("routine calldata self-check failed");
 if(CRIT.targets.length!==crit.length||ROUTINE.targets.length!==rout.length)throw new Error("length mismatch");
 console.log("calldata self-check passed:",crit.length,"critical and",rout.length,"routine actions");
}
async function main(){
 const cmd=process.argv[2]||"check";
 check();
 if(cmd==="check")return;
 const rpc=process.env.OMNICOIN_RPC_URL||"https://rpc.omnicoin.net";
 const provider=new ethers.JsonRpcProvider(rpc,88008,{staticNetwork:true});
 const keyFile=(process.env.GOV_KEY_FILE||"").replace(/^~/,os.homedir());
 if(!keyFile)throw new Error("set GOV_KEY_FILE to the recovery treasury key file");
 const raw=fs.readFileSync(keyFile,"utf8").trim();
 const wallet=new ethers.Wallet(raw.startsWith("0x")?raw:"0x"+raw,provider);
 const me=await wallet.getAddress();
 if(me.toLowerCase()!==TREASURY.toLowerCase())throw new Error("the loaded key derives "+me+", not the recovery treasury. Nothing sent.");
 console.log("signing as the recovery treasury",me);
 const gov=new ethers.Contract(GOVERNOR,ABI,wallet);
 if(cmd==="propose"){
   const routine=process.argv.includes("--routine");
   const set=routine?ROUTINE:CRIT;
   const type=routine?ROUTE:CRITICAL;
   const text=DESC+" ("+(routine?"routine":"critical")+")";
   const tx=await gov.propose(type,set.targets,set.targets.map(()=>0n),set.calldatas,text,{gasLimit:3000000n,gasPrice:2n});
   console.log("propose sent",tx.hash);
   const r=await tx.wait();
   if(!r||r.status!==1)throw new Error("propose reverted in "+tx.hash);
   const id=await gov.proposalCount();
   console.log("proposal",id.toString(),"created in block",r.blockNumber);
   const rec=path.join(os.homedir(),"pause-proposals.json");
   const prev=fs.existsSync(rec)?JSON.parse(fs.readFileSync(rec,"utf8")):{};
   prev[routine?"routine":"critical"]={id:id.toString(),txHash:tx.hash};
   fs.writeFileSync(rec,JSON.stringify(prev,null,2));
   console.log("recorded in",rec);
   return;
 }
 const id=BigInt(process.env.PROPOSAL_ID||"0");
 if(!id)throw new Error("set PROPOSAL_ID");
 if(cmd==="vote"){const tx=await gov.castVote(id,FOR,{gasLimit:500000n,gasPrice:2n});console.log("vote sent",tx.hash);await tx.wait();return;}
 if(cmd==="queue"||cmd==="execute"){const tx=await gov[cmd](id,{gasLimit:6000000n,gasPrice:2n});console.log(cmd,"sent",tx.hash);const r=await tx.wait();console.log("status",r.status);return;}
 throw new Error("unknown command "+cmd);
}
main().catch(e=>{console.error("FAILED:",e.message);process.exit(1);});
