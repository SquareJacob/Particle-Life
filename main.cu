#include <SDL.h>
#include <SDL_image.h>
#include <SDL_ttf.h>
#include <SDL_mixer.h>
#include <iostream>
#include <stdlib.h>  
#include <crtdbg.h>   //for malloc and free
#include <set>
#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include <stdio.h>
#include <string>
#include <fstream>
#include <windows.h>
#define _CRTDBG_MAP_ALLOC
#ifdef _DEBUG
#define new new( _NORMAL_BLOCK, __FILE__, __LINE__)
#endif

SDL_Window* window;
SDL_Renderer* renderer;
bool running;
SDL_Event event;
std::set<std::string> keys;
std::set<std::string> currentKeys;
int mouseX = 0;
int mouseY = 0;
int mouseDeltaX = 0;
int mouseDeltaY = 0;
int mouseScroll = 0;
std::set<int> buttons;
std::set<int> currentButtons;
const int WIDTH = 600;
const int HEIGHT = 600;
const int CONTROLWIDTH = 200;

void debug(int line, std::string file) {
	std::cout << "Line " << line << " in file " << file << ": " << SDL_GetError() << std::endl;
}

std::string lowercase(std::string str)
{
	std::string result = "";

	for (char ch : str) {
		// Convert each character to lowercase using tolower 
		result += tolower(ch);
	}

	return result;
}

double rmin = 5.0;
double rmax = 50.0;
double repulse = 1.0;
__device__ double force(double attract, double distance, double rmin, double rmax, double repulse) {
	if (distance >= rmax) {
		return 0.0;
	}
	if (distance >= (rmin + rmax) / 2.0) {
		return 2.0 * attract / (rmax - rmin) * (rmax - distance);
	}
	if (distance >= rmin) {
		return 2.0 * attract / (rmax - rmin) * (distance - rmin);
	}
	return repulse * distance / rmin - repulse;
}

double random() {
	return static_cast<float>(rand()) / static_cast<float>(RAND_MAX);
}

const uint8_t numTypes = 6; //KEEP AT 7 OR BELOW
double friction = 1.0;
double speed;
const SDL_Color colors[] = { {255, 0, 0}, {0, 255, 0}, {0, 0, 255}, {255, 80, 237}, {195, 97, 97}, {255, 215, 0} };
class Particle {
public:
	uint8_t type = 0, r = 0, g = 0, b = 0;
	double x = 0.0, y = 0.0, xvel = 0.0, yvel = 0.0;
	void move(double frame) {
		x += frame * xvel;
		y += frame * yvel;
		if (x < 0) {
			x += WIDTH;
		}
		else if (x > WIDTH) {
			x -= WIDTH;
		}
		if (y < 0) {
			y += HEIGHT;
		}
		else if (y > HEIGHT) {
			y -= HEIGHT;
		}
		speed = hypot(xvel, yvel);
		if (speed < friction) {
			xvel = 0.0;
			yvel = 0.0;
		}
		else {
			xvel -= friction * xvel / speed;
			yvel -= friction * yvel / speed;
		}
	}
	void draw() {
		SDL_SetRenderDrawColor(renderer, r, g, b, 255);
		SDL_RenderDrawPoint(renderer, static_cast<int>(x), static_cast<int>(y));
	}
};

class Button {
public:
	uint8_t r = 0, g = 0, b = 0;
	SDL_Rect rect = { 0, 0, 0, 0 };
	bool hovered() {
		return rect.x < mouseX && mouseX < rect.x + rect.w && rect.y < mouseY && mouseY < rect.y + rect.h;
	}
	void draw() {
		SDL_SetRenderDrawColor(renderer, r, g, b, 255);
		SDL_RenderFillRect(renderer, &rect);
		SDL_SetRenderDrawColor(renderer, 255, 255, 255, 255);
		SDL_RenderDrawRect(renderer, &rect);
	}
	void setRGB(double attraction) {
		if (attraction > 0.0) {
			g = 255 * attraction;
			r = 0;
		}
		else {
			r = 255 * -attraction;
			g = 0;
		}
	}
};
Button attractButtons[numTypes * numTypes]; //numTypes * [type1] + [type2], where type1 attracts type2
Button exportButton;

TTF_Font* font;
class Text {
public:
	SDL_Rect rect = { 0, 0, 0, 0 };
	SDL_Texture* texture = NULL;
	~Text() {
		removeTexture();
	}
	void draw() {
		if (SDL_RenderCopy(renderer, texture, NULL, &rect) != 0) {
			debug(__LINE__, __FILE__);
		}
	}
	void removeTexture() {
		if (texture != NULL) {
			SDL_DestroyTexture(texture);
			texture = NULL;
		}
	}
	void createTexture(std::string text, int height) {
		SDL_Surface* tmp = TTF_RenderText_Solid(font, text.c_str(), { 255, 255, 255 });
		if (tmp == NULL) {
			debug(__LINE__, __FILE__);
			return;
		}
		removeTexture();
		texture = SDL_CreateTextureFromSurface(renderer, tmp);
		rect.h = height;
		rect.w = tmp->w * height / tmp->h;
		SDL_FreeSurface(tmp);
		if (texture == NULL) {
			debug(__LINE__, __FILE__);
		}

	}
};
Text repText, attractText, exportText, outputText;

class Slider {
public:
	Text label;
	Button bar, handle;
	Slider() {
		handle.r = 255;
		handle.g = 255;
		handle.b = 255;
		handle.rect.w = 6;

		bar.r = 255;
		bar.g = 255;
		bar.b = 255;
		bar.rect.h = 6;
	}
	void setText(std::string text, int height) {
		label.createTexture(text, height);
		handle.rect.h = label.rect.h;
	}
	void setPos(int x, int y) {
		label.rect.x = x;
		label.rect.y = y;
		handle.rect.x = label.rect.w + 10 + x - handle.rect.w / 2;
		handle.rect.y = y;
		bar.rect.x = x + label.rect.w + 10;
		bar.rect.y = y - (bar.rect.h - handle.rect.h) / 2;
	}
	void setValue(double value) {
		handle.rect.x = bar.rect.x - handle.rect.w / 2 + value * bar.rect.w;
	}
	double getValue() {
		return static_cast<float>(handle.rect.x + handle.rect.w / 2 - bar.rect.x) / static_cast<float>(bar.rect.w);
	}
	double update() {
		if ((bar.hovered() || handle.hovered()) && buttons.contains(1)) {
			handle.rect.x = std::max(bar.rect.x, std::min(mouseX, bar.rect.x + bar.rect.w)) - handle.rect.w / 2;
		}
		bar.draw();
		handle.draw();
		label.draw();
		return getValue();
	}
};
Slider rminSlider, rmaxSlider, repSlider, fricSlider;
SDL_Rect repRect = { 0 };

const uint16_t THREADS = 256; //keep square
const uint16_t numParticles = 6000; //Keep as a multiple of sqrt(THREADS)
const dim3 BLOCKS(375, 375); //numParticles / sqrt(THREADS)

Particle particles[numParticles];
Particle* d_particles;
size_t p_size = sizeof(Particle) * static_cast<size_t>(numParticles);
double attractions[numTypes * numTypes]; //numTypes * [type1] + [type2], where type1 attracts type2
double* d_attractions;

bool exporting = false;
std::string key, fileName;

void allocateAttractions() {
	cudaMalloc((void**)&d_attractions, sizeof(double) * static_cast<size_t>(numTypes * numTypes));
	cudaMemcpy(d_attractions, attractions, sizeof(double) * static_cast<size_t>(numTypes * numTypes), cudaMemcpyHostToDevice);
}

void setAttractions() {
	cudaFree(d_attractions);
	for (uint8_t i = 0; i < numTypes * numTypes; i++) {
		attractions[i] = 2.0 * random() - 1.0;
		attractButtons[i].setRGB(attractions[i]);

	}
	allocateAttractions();
}

void setParticles() {
	uint8_t type;
	for (uint16_t i = 0; i < numParticles; i++) {
		type = rand() % numTypes;
		particles[i].type = type;
		particles[i].r = colors[type].r;
		particles[i].g = colors[type].g;
		particles[i].b = colors[type].b;
		particles[i].x = static_cast<float>(WIDTH) * random();
		particles[i].y = static_cast<float>(HEIGHT) * random();
	}
}

void randomize() {
	setAttractions();
	repSlider.setValue(random());
	rminSlider.setValue(random());
	rmaxSlider.setValue(random());
	fricSlider.setValue(random());
	setParticles();
}

Uint32 startTime, totalTime, startCalc, startDraw;

__global__ void totalForce(Particle particles[numParticles], double attractions[numTypes * numTypes], Uint32 totalTime, double rmin, double rmax, double repulse) {
	double disX, disY, dis, attraction;
	Uint32 index = (blockIdx.x * blockDim.x + blockIdx.y) * static_cast<Uint32>(THREADS) + threadIdx.x;
	Uint16 i = index / numParticles;
	Uint16 j = index % numParticles;
	disX = particles[i].x - particles[j].x;
	if (disX > WIDTH / 2) {
		disX -= WIDTH;
	}
	else if (disX < -WIDTH / 2) {
		disX += WIDTH;
	}
	disY = particles[i].y - particles[j].y;
	if (disY > HEIGHT / 2) {
		disY -= HEIGHT / 2;
	}
	else if (disY < -HEIGHT / 2) {
		disY += HEIGHT / 2;
	}
	dis = hypot(disX, disY);
	if (dis > 0.0) {
		attraction = force(attractions[numTypes * particles[i].type + particles[j].type], dis, rmin, rmax, repulse) / dis;
		//std::cout << ' ' << attraction << std::endl;
		particles[j].xvel += disX * attraction;
		particles[j].yvel += disY * attraction;
	}
}

bool timing = false;
int main(int argc, char* argv[]) {
	std::string path0(argv[0]);
	std::string path = path0.substr(0, path0.length() - 18);
	int deviceCount;
	cudaGetDeviceCount(&deviceCount);
	if (deviceCount == 0) {
		std::cerr << "Uh oh, looks like your graphics card sucks, dawg. Can't run this. Womp womp" << std::endl;
		return 1;
	}
	if (SDL_Init(SDL_INIT_EVERYTHING) == 0 && TTF_Init() == 0 && Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 2048) == 0) {
		//Setup
		window = SDL_CreateWindow("Window", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, WIDTH + CONTROLWIDTH, HEIGHT, 0);
		if (window == NULL) {
			debug(__LINE__, __FILE__);
			return 0;
		}

		renderer = SDL_CreateRenderer(window, -1, 0);
		if (renderer == NULL) {
			debug(__LINE__, __FILE__);
			return 0;
		}

		srand(time(0));
		setParticles();
		allocateAttractions();
		Button* a;
		int size = CONTROLWIDTH / (numTypes + 1);
		for (uint8_t i = 0; i < numTypes * numTypes; i++) {
			a = &attractButtons[i];
			a->rect = { WIDTH + size / 2 + size * (i % numTypes), size / 2 + size * (i / numTypes), size, size };
		}
		font = TTF_OpenFont((path + "/font.otf").c_str(), CONTROLWIDTH / 10);
		if (font == NULL) {
			debug(__LINE__, __FILE__);
		}


		repSlider.setText("rep", CONTROLWIDTH / 10);
		repSlider.setPos(WIDTH + 5, size * numTypes + size);
		repSlider.bar.rect.w = CONTROLWIDTH + WIDTH - repSlider.bar.rect.x - 5;
		repSlider.setValue(0.5);

		rminSlider.setText("rmin", repSlider.label.rect.h);
		rminSlider.setPos(repSlider.label.rect.x, repSlider.label.rect.y + repSlider.label.rect.h + 10);
		rminSlider.bar.rect.w = CONTROLWIDTH + WIDTH - rminSlider.bar.rect.x - 5;
		rminSlider.setValue(0.5);

		rmaxSlider.setText("rmax", repSlider.label.rect.h);
		rmaxSlider.setPos(repSlider.label.rect.x, rminSlider.label.rect.y + rminSlider.label.rect.h + 10);
		rmaxSlider.bar.rect.w = CONTROLWIDTH + WIDTH - rmaxSlider.bar.rect.x - 5;
		rmaxSlider.setValue(0.5);

		fricSlider.setText("fric", repSlider.label.rect.h);
		fricSlider.setPos(repSlider.label.rect.x, rmaxSlider.label.rect.y + rmaxSlider.label.rect.h + 10);
		fricSlider.bar.rect.w = CONTROLWIDTH + WIDTH - fricSlider.bar.rect.x - 5;
		fricSlider.setValue(0.5);

		repRect = { 0, fricSlider.label.rect.y + fricSlider.label.rect.h + size / 2, size, size };

		repText.createTexture("Column is attracted to row", CONTROLWIDTH / 10);
		repText.rect.x = WIDTH + (CONTROLWIDTH - repText.rect.w) / 2;
		repText.rect.y = repRect.y + repRect.h + size / 2;

		attractText.createTexture("0", CONTROLWIDTH / 10);
		attractText.rect.x = WIDTH + size / 2;
		attractText.rect.y = repText.rect.y + repText.rect.h + size / 2;

		exportText.createTexture("Export", CONTROLWIDTH / 10);
		exportText.rect.x = attractText.rect.x;
		exportText.rect.y = attractText.rect.y + attractText.rect.h + size / 2;

		exportButton.r = 255;
		exportButton.rect = exportText.rect;

		outputText.rect.x = exportButton.rect.x;
		outputText.rect.y = exportButton.rect.y + exportButton.rect.h + size / 2;

		if (argc > 1) {
			std::ifstream myfile(argv[1]);
			if (myfile.is_open()) {
				std::string line;
				double inputs[numTypes * numTypes + 4];
				uint16_t j = 0;
				while (getline(myfile, line, ' ') && j < numTypes * numTypes + 4) {
					inputs[j] = std::stod(line);
					j++;
				}
				myfile.close();
				for (uint16_t i = 0; i < numTypes * numTypes; i++) {
					attractions[i] = inputs[i];
					attractButtons[i].setRGB(attractions[i]);
				}
				repSlider.setValue(inputs[numTypes * numTypes]);
				rminSlider.setValue(inputs[numTypes * numTypes + 1]);
				rmaxSlider.setValue(inputs[numTypes * numTypes + 2]);
				fricSlider.setValue(inputs[numTypes * numTypes + 3]);
				allocateAttractions();
			}
		}


		cudaSetDevice(0);
		cudaMalloc((void**)&d_particles, p_size);

		//Main loop
		running = true;
		while (running) {
			startTime = SDL_GetTicks();
			//handle events
			for (std::string i : keys) {
				currentKeys.erase(i); //make sure only newly pressed keys are in currentKeys
			}
			for (int i : buttons) {
				currentButtons.erase(i); //make sure only newly pressed buttons are in currentButtons
			}
			mouseScroll = 0;
			while (SDL_PollEvent(&event)) {
				switch (event.type) {
				case SDL_QUIT:
					running = false;
					break;
				case SDL_KEYDOWN:
					if (!keys.contains(std::string(SDL_GetKeyName(event.key.keysym.sym)))) {
						currentKeys.insert(std::string(SDL_GetKeyName(event.key.keysym.sym)));
					}
					keys.insert(std::string(SDL_GetKeyName(event.key.keysym.sym))); //add keydown to keys set
					break;
				case SDL_KEYUP:
					keys.erase(std::string(SDL_GetKeyName(event.key.keysym.sym))); //remove keyup from keys set
					break;
				case SDL_MOUSEMOTION:
					mouseX = event.motion.x;
					mouseY = event.motion.y;
					mouseDeltaX = event.motion.xrel;
					mouseDeltaY = event.motion.yrel;
					break;
				case SDL_MOUSEBUTTONDOWN:
					if (!buttons.contains(event.button.button)) {
						currentButtons.insert(event.button.button);
					}
					buttons.insert(event.button.button);
					break;
				case SDL_MOUSEBUTTONUP:
					buttons.erase(event.button.button);
					break;
				case SDL_MOUSEWHEEL:
					mouseScroll = event.wheel.y;
					break;
				}
			}

			if (currentKeys.contains("B")) {
				randomize();
			}

			startCalc = SDL_GetTicks();
			cudaMemcpy(d_particles, particles, p_size, cudaMemcpyHostToDevice);
			totalForce << <BLOCKS, THREADS >> > (d_particles, d_attractions, totalTime, rmin, rmax, repulse);
			cudaDeviceSynchronize();
			cudaMemcpy(particles, d_particles, p_size, cudaMemcpyDeviceToHost);
			if (timing) {
				std::cout << "calc time: " << SDL_GetTicks() - startCalc;
			}

			startDraw = SDL_GetTicks();
			SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
			SDL_RenderClear(renderer);
			for (uint16_t i = 0; i < numParticles; i++) {
				particles[i].move(0.3);
				particles[i].draw();
			}
			Button* a;
			for (uint16_t i = 0; i < numTypes * numTypes; i++) {
				a = &attractButtons[i];
				if (a->hovered()) {
					if (buttons.contains(1)) {
						attractions[i] = std::min(attractions[i] + 0.01, 1.0);
						allocateAttractions();
						a->setRGB(attractions[i]);
					}
					else if (buttons.contains(3)) {
						attractions[i] = std::max(attractions[i] - 0.01, -1.0);
						allocateAttractions();
						a->setRGB(attractions[i]);
					}
					if (keys.contains("0")) {
						attractions[i] = 0;
						a->setRGB(attractions[i]);
						allocateAttractions();
					}
					attractText.createTexture(std::to_string(attractions[i]), attractText.rect.h);
				}
				a->draw();
			}
			repulse = 2.0 * repSlider.update();
			rmin = 10.0 * rminSlider.update();
			rmax = rmin + 15.0 + 75.0 * rmaxSlider.update();
			friction = 2.0 * fricSlider.update() + 2.0;
			repText.draw();
			attractText.draw();
			if (exportButton.hovered() && currentButtons.contains(1)) {
				exporting = true;
				fileName = "";
			}
			if (exporting) {
				if (currentKeys.size() > 0) {
					key = *currentKeys.begin();
					if (key == "Return") {
						if (fileName.length() == 0) {
							fileName = "Preset";
						}
						fileName += ".pal";
						std::ofstream outFile(path + "/Presets/" + fileName);
						if (!outFile.is_open()) {
							std::cout << path + "/Presets/" + fileName << " didn't work :(" << std::endl;
						}
						for (uint8_t i = 0; i < numTypes * numTypes; i++) {
							outFile << attractions[i] << ' ';
						}
						outFile << repSlider.getValue() << ' ';
						outFile << rminSlider.getValue() << ' ';
						outFile << rmaxSlider.getValue() << ' ';
						outFile << fricSlider.getValue() << std::endl;
						outFile.close();
						exporting = false;
					}
					else if (key == "Space") {
						key = " ";
					}
					else {
						key = lowercase(key);
					}
					if (exporting) {
						fileName += key;
						outputText.createTexture(fileName, exportButton.rect.h);
					}
				}
				if (fileName.length() > 0) {
					outputText.draw();
				}
			}
			exportButton.draw();
			exportText.draw();
			for (uint8_t i = 0; i < numTypes; i++) {
				repRect.x = WIDTH + size / 2 + size * i;
				SDL_SetRenderDrawColor(renderer, colors[i].r, colors[i].g, colors[i].b, 255);
				SDL_RenderFillRect(renderer, &repRect);
			}
			SDL_RenderPresent(renderer);
			if (timing) {
				std::cout << " draw time: " << SDL_GetTicks() - startDraw;
			}

			totalTime = SDL_GetTicks() - startTime;
			if (timing) {
				std::cout << " total time: " << totalTime << std::endl;
			}
			//cudaError_t err = cudaGetLastError();
			//std::cout << "Error: " << cudaGetErrorString(err) << std::endl;
			//std::cout << repulse << std::endl;
		}
		
		//Clean up
		cudaFree(d_particles);
		cudaFree(d_attractions);
		TTF_CloseFont(font);
		if (window) {
			SDL_DestroyWindow(window);
		}
		if (renderer) {
			SDL_DestroyRenderer(renderer);
		}
		TTF_Quit();
		Mix_Quit();
		IMG_Quit();
		SDL_Quit();
		return 0;
	}
	else {
		return 0;
	}
}