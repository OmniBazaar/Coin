const fs = require('fs');
const path = require('path');

// Security analysis script for OmniCoin contracts
class SecurityAnalyzer {
    constructor() {
        this.vulnerabilities = [];
        this.contractsDir = './contracts';
        this.patterns = {
            // High-risk patterns
            reentrancy: [
                /external.*call/g,
                /\.call\(/g,
                /\.delegatecall\(/g,
                /\.send\(/g,
                /\.transfer\(/g
            ],
            uncheckedCalls: [
                /\.call\([^)]*\)(?!\s*(?:;|\)|\}|require|assert))/g,
                /\.delegatecall\([^)]*\)(?!\s*(?:;|\)|\}|require|assert))/g
            ],
            integerOverflow: [
                /\+\+/g,
                /\+=/g,
                /-=/g,
                /\*=/g,
                /\/=/g,
                /\baddition\b/g,
                /\bsubtraction\b/g,
                /\bmultiplication\b/g
            ],
            gasLimits: [
                /for\s*\(/g,
                /while\s*\(/g,
                /\.length/g
            ],
            accessControl: [
                /onlyOwner/g,
                /msg\.sender/g,
                /tx\.origin/g,
                /require\(/g,
                /modifier/g
            ],
            randomness: [
                /block\.timestamp/g,
                /block\.number/g,
                /block\.difficulty/g,
                /blockhash/g,
                /now/g
            ],
            // Medium-risk patterns
            visibility: [
                /function.*public/g,
                /function.*external/g,
                /function.*internal/g,
                /function.*private/g
            ],
            stateVariables: [
                /mapping\s*\(/g,
                /storage/g,
                /memory/g
            ]
        };
    }

    analyzeContract(filePath) {
        const content = fs.readFileSync(filePath, 'utf8');
        const contractName = path.basename(filePath, '.sol');
        
        console.log(`\n=== Analyzing ${contractName} ===`);
        
        // Check for reentrancy vulnerabilities
        this.checkReentrancy(contractName, content);
        
        // Check for unchecked external calls
        this.checkUncheckedCalls(contractName, content);
        
        // Check for integer overflow/underflow
        this.checkIntegerOverflow(contractName, content);
        
        // Check for gas limit vulnerabilities
        this.checkGasLimits(contractName, content);
        
        // Check access control
        this.checkAccessControl(contractName, content);
        
        // Check randomness issues
        this.checkRandomness(contractName, content);
        
        // Check function visibility
        this.checkVisibility(contractName, content);
        
        // Check for TODOs and FIXMEs
        this.checkTodos(contractName, content);
        
        // Check for hardcoded addresses
        this.checkHardcodedAddresses(contractName, content);
        
        return this.vulnerabilities;
    }
    
    checkReentrancy(contractName, content) {
        const lines = content.split('\n');
        const hasReentrancyGuard = /ReentrancyGuard/g.test(content);
        const hasNonReentrant = /nonReentrant/g.test(content);
        
        this.patterns.reentrancy.forEach(pattern => {
            const matches = content.match(pattern);
            if (matches) {
                lines.forEach((line, index) => {
                    if (pattern.test(line)) {
                        if (!hasReentrancyGuard || !hasNonReentrant) {
                            this.addVulnerability(contractName, 'HIGH', 'Reentrancy', 
                                `Potential reentrancy vulnerability at line ${index + 1}: ${line.trim()}`, 
                                'Use ReentrancyGuard and nonReentrant modifier');
                        }
                    }
                });
            }
        });
    }
    
    checkUncheckedCalls(contractName, content) {
        const lines = content.split('\n');
        this.patterns.uncheckedCalls.forEach(pattern => {
            lines.forEach((line, index) => {
                if (pattern.test(line)) {
                    this.addVulnerability(contractName, 'HIGH', 'Unchecked Call', 
                        `Unchecked external call at line ${index + 1}: ${line.trim()}`, 
                        'Always check return values of external calls');
                }
            });
        });
    }
    
    checkIntegerOverflow(contractName, content) {
        const lines = content.split('\n');
        const hasSafeMath = /SafeMath/g.test(content);
        const isVersionGte08 = /pragma solidity.*0\.8/g.test(content);
        
        if (!hasSafeMath && !isVersionGte08) {
            this.patterns.integerOverflow.forEach(pattern => {
                lines.forEach((line, index) => {
                    if (pattern.test(line) && !/\/\//g.test(line)) {
                        this.addVulnerability(contractName, 'MEDIUM', 'Integer Overflow', 
                            `Potential integer overflow at line ${index + 1}: ${line.trim()}`, 
                            'Use SafeMath library or Solidity 0.8+');
                    }
                });
            });
        }
    }
    
    checkGasLimits(contractName, content) {
        const lines = content.split('\n');
        lines.forEach((line, index) => {
            if (/for\s*\(/g.test(line) || /while\s*\(/g.test(line)) {
                if (/\.length/g.test(line)) {
                    this.addVulnerability(contractName, 'MEDIUM', 'Gas Limit', 
                        `Potential gas limit issue at line ${index + 1}: ${line.trim()}`, 
                        'Limit loop iterations or use pagination');
                }
            }
        });
    }
    
    checkAccessControl(contractName, content) {
        const lines = content.split('\n');
        const hasAccessControl = /AccessControl/g.test(content) || /Ownable/g.test(content);
        
        lines.forEach((line, index) => {
            if (/tx\.origin/g.test(line)) {
                this.addVulnerability(contractName, 'HIGH', 'Access Control', 
                    `Use of tx.origin at line ${index + 1}: ${line.trim()}`, 
                    'Use msg.sender instead of tx.origin');
            }
            
            if (/function.*public/g.test(line) && !/view|pure/g.test(line)) {
                if (!hasAccessControl || !/onlyOwner|require/g.test(line)) {
                    this.addVulnerability(contractName, 'MEDIUM', 'Access Control', 
                        `Public function without access control at line ${index + 1}: ${line.trim()}`, 
                        'Add proper access control modifiers');
                }
            }
        });
    }
    
    checkRandomness(contractName, content) {
        const lines = content.split('\n');
        const randomnessPatterns = [
            { pattern: /block\.timestamp/g, name: 'block.timestamp' },
            { pattern: /block\.number/g, name: 'block.number' },
            { pattern: /block\.difficulty/g, name: 'block.difficulty' },
            { pattern: /blockhash/g, name: 'blockhash' },
            { pattern: /\bnow\b/g, name: 'now' }
        ];
        
        randomnessPatterns.forEach(({pattern, name}) => {
            lines.forEach((line, index) => {
                if (pattern.test(line) && /random|seed|nonce/gi.test(line)) {
                    this.addVulnerability(contractName, 'MEDIUM', 'Weak Randomness', 
                        `Potential weak randomness using ${name} at line ${index + 1}: ${line.trim()}`, 
                        'Use secure randomness source like Chainlink VRF');
                }
            });
        });
    }
    
    checkVisibility(contractName, content) {
        const lines = content.split('\n');
        lines.forEach((line, index) => {
            if (/function/g.test(line) && !/public|external|internal|private/g.test(line)) {
                this.addVulnerability(contractName, 'LOW', 'Visibility', 
                    `Function without explicit visibility at line ${index + 1}: ${line.trim()}`, 
                    'Always specify function visibility');
            }
        });
    }
    
    checkTodos(contractName, content) {
        const lines = content.split('\n');
        lines.forEach((line, index) => {
            if (/TODO|FIXME|XXX|HACK/gi.test(line)) {
                this.addVulnerability(contractName, 'LOW', 'Code Quality', 
                    `Unresolved TODO/FIXME at line ${index + 1}: ${line.trim()}`, 
                    'Complete or remove TODO/FIXME comments');
            }
        });
    }
    
    checkHardcodedAddresses(contractName, content) {
        const lines = content.split('\n');
        const addressPattern = /0x[a-fA-F0-9]{40}/g;
        
        lines.forEach((line, index) => {
            const matches = line.match(addressPattern);
            if (matches && !/address\(0\)/g.test(line)) {
                matches.forEach(addr => {
                    this.addVulnerability(contractName, 'MEDIUM', 'Hardcoded Address', 
                        `Hardcoded address ${addr} at line ${index + 1}: ${line.trim()}`, 
                        'Use configuration or constructor parameters');
                });
            }
        });
    }
    
    addVulnerability(contract, severity, category, description, recommendation) {
        this.vulnerabilities.push({
            contract,
            severity,
            category,
            description,
            recommendation,
            timestamp: new Date().toISOString()
        });
    }
    
    generateReport() {
        const report = {
            summary: {
                total: this.vulnerabilities.length,
                high: this.vulnerabilities.filter(v => v.severity === 'HIGH').length,
                medium: this.vulnerabilities.filter(v => v.severity === 'MEDIUM').length,
                low: this.vulnerabilities.filter(v => v.severity === 'LOW').length
            },
            vulnerabilities: this.vulnerabilities,
            timestamp: new Date().toISOString()
        };
        
        return report;
    }
    
    runAnalysis() {
        const contractFiles = fs.readdirSync(this.contractsDir)
            .filter(file => file.endsWith('.sol'))
            .map(file => path.join(this.contractsDir, file));
        
        console.log(`Starting security analysis on ${contractFiles.length} contracts...`);
        
        contractFiles.forEach(file => {
            try {
                this.analyzeContract(file);
            } catch (error) {
                console.error(`Error analyzing ${file}:`, error.message);
            }
        });
        
        const report = this.generateReport();
        
        // Save report
        fs.writeFileSync('./security_report.json', JSON.stringify(report, null, 2));
        
        // Print summary
        console.log('\n=== SECURITY ANALYSIS SUMMARY ===');
        console.log(`Total vulnerabilities found: ${report.summary.total}`);
        console.log(`High severity: ${report.summary.high}`);
        console.log(`Medium severity: ${report.summary.medium}`);
        console.log(`Low severity: ${report.summary.low}`);
        
        if (report.summary.high > 0) {
            console.log('\n=== HIGH SEVERITY VULNERABILITIES ===');
            report.vulnerabilities
                .filter(v => v.severity === 'HIGH')
                .forEach(v => {
                    console.log(`${v.contract}: ${v.category} - ${v.description}`);
                });
        }
        
        console.log('\nFull report saved to security_report.json');
        
        return report;
    }
}

// Run the analysis
const analyzer = new SecurityAnalyzer();
analyzer.runAnalysis(); 