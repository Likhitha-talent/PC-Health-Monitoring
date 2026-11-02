/**
 * High-Tech Chart.js Visualizations Controller
 * Styled with Neon Spline Curves, Glowing Gradient Areas, and Monospace Tooltips
 */
const TelemetryCharts = {
  realtimeChart: null,
  historicalChart: null,
  maxPoints: 12, // 12 samples * 5s = 60s rolling window

  init() {
    this.initRealtimeChart();
    this.initHistoricalChart();
  },

  initRealtimeChart() {
    const ctx = document.getElementById('realtimeChart');
    if (!ctx) return;

    // Create neon gradient fills
    const canvas = ctx.getContext('2d');
    const cpuGradient = canvas.createLinearGradient(0, 0, 0, 260);
    cpuGradient.addColorStop(0, 'rgba(0, 242, 254, 0.35)');
    cpuGradient.addColorStop(1, 'rgba(0, 242, 254, 0.00)');

    const ramGradient = canvas.createLinearGradient(0, 0, 0, 260);
    ramGradient.addColorStop(0, 'rgba(157, 78, 221, 0.30)');
    ramGradient.addColorStop(1, 'rgba(157, 78, 221, 0.00)');

    // Initial dummy timestamps
    const labels = [];
    const now = new Date();
    for (let i = this.maxPoints - 1; i >= 0; i--) {
      const t = new Date(now.getTime() - i * 5000);
      labels.push(t.toTimeString().split(' ')[0]);
    }

    this.realtimeChart = new Chart(ctx, {
      type: 'line',
      data: {
        labels: labels,
        datasets: [
          {
            label: 'CPU Load (%)',
            data: [22, 28, 25, 30, 45, 38, 29, 34, 40, 36, 30, 32],
            borderColor: '#00f2fe',
            borderWidth: 2.5,
            backgroundColor: cpuGradient,
            fill: true,
            tension: 0.35,
            pointRadius: 3,
            pointHoverRadius: 6,
            pointBackgroundColor: '#00f2fe',
            pointBorderColor: '#060913',
            pointBorderWidth: 2
          },
          {
            label: 'RAM Load (%)',
            data: [68, 68, 69, 70, 71, 71, 70, 72, 73, 72, 71, 71],
            borderColor: '#9d4edd',
            borderWidth: 2.5,
            backgroundColor: ramGradient,
            fill: true,
            tension: 0.35,
            pointRadius: 3,
            pointHoverRadius: 6,
            pointBackgroundColor: '#9d4edd',
            pointBorderColor: '#060913',
            pointBorderWidth: 2
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: { duration: 600 },
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: 'rgba(11, 17, 34, 0.95)',
            titleColor: '#00f2fe',
            bodyColor: '#f0f6fc',
            borderColor: 'rgba(0, 242, 254, 0.3)',
            borderWidth: 1,
            titleFont: { family: 'JetBrains Mono', size: 11 },
            bodyFont: { family: 'JetBrains Mono', size: 11 },
            padding: 10
          }
        },
        scales: {
          x: {
            grid: { color: 'rgba(255, 255, 255, 0.04)' },
            ticks: { color: '#53627a', font: { family: 'JetBrains Mono', size: 9 }, maxRotation: 0 }
          },
          y: {
            min: 0,
            max: 100,
            grid: { color: 'rgba(255, 255, 255, 0.04)' },
            ticks: {
              color: '#53627a',
              font: { family: 'JetBrains Mono', size: 9 },
              callback: (val) => val + '%'
            }
          }
        }
      }
    });
  },

  initHistoricalChart() {
    const ctx = document.getElementById('historicalChart');
    if (!ctx) return;

    // 24 Hour labels
    const hours = [];
    const avgCpu = [];
    const peakCpu = [];
    for (let h = 0; h < 12; h++) {
      hours.push(`${h * 2}:00`);
      avgCpu.push(Math.round(25 + Math.random() * 25));
      peakCpu.push(Math.round(65 + Math.random() * 30));
    }

    this.historicalChart = new Chart(ctx, {
      type: 'bar',
      data: {
        labels: hours,
        datasets: [
          {
            type: 'line',
            label: 'Peak Spike (%)',
            data: peakCpu,
            borderColor: '#ffaa00',
            borderWidth: 2,
            borderDash: [4, 4],
            pointRadius: 2,
            tension: 0.2
          },
          {
            type: 'bar',
            label: 'Avg CPU (%)',
            data: avgCpu,
            backgroundColor: 'rgba(0, 242, 254, 0.45)',
            hoverBackgroundColor: '#00f2fe',
            borderRadius: 4,
            borderWidth: 0
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: {
            backgroundColor: 'rgba(11, 17, 34, 0.95)',
            borderColor: 'rgba(255, 170, 0, 0.3)',
            borderWidth: 1,
            titleFont: { family: 'JetBrains Mono', size: 10 },
            bodyFont: { family: 'JetBrains Mono', size: 10 }
          }
        },
        scales: {
          x: {
            grid: { display: false },
            ticks: { color: '#53627a', font: { family: 'JetBrains Mono', size: 9 } }
          },
          y: {
            min: 0,
            max: 100,
            grid: { color: 'rgba(255, 255, 255, 0.04)' },
            ticks: {
              color: '#53627a',
              font: { family: 'JetBrains Mono', size: 9 },
              callback: (val) => val + '%'
            }
          }
        }
      }
    });
  },

  pushRealtimePoint(timeLabel, cpuVal, ramVal) {
    if (!this.realtimeChart) return;

    const data = this.realtimeChart.data;
    data.labels.push(timeLabel);
    data.datasets[0].data.push(cpuVal);
    data.datasets[1].data.push(ramVal);

    if (data.labels.length > this.maxPoints) {
      data.labels.shift();
      data.datasets[0].data.shift();
      data.datasets[1].data.shift();
    }

    this.realtimeChart.update('none'); // Fast update without full animation re-render
  },

  updateHistoricalData(labels, avgCpuList, peakCpuList) {
    if (!this.historicalChart) return;
    this.historicalChart.data.labels = labels;
    this.historicalChart.data.datasets[0].data = peakCpuList;
    this.historicalChart.data.datasets[1].data = avgCpuList;
    this.historicalChart.update();
  }
};
